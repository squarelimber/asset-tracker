import 'package:drift/drift.dart' show Value;

import '../core/enums.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/portfolio_calculator.dart';
import '../domain/rule_engine.dart';
import '../domain/target_allocation.dart';
import 'market/market_service.dart';

/// Runs all enabled alert rules, dedups by day, and persists fired events.
class AlertService {
  AlertService(this._dao);

  final AssetDao _dao;
  static const String lastCheckedKey = 'alerts_last_checked_at';

  /// Evaluates all enabled rules. Returns events that are new (not fired
  /// today for the same rule+message).
  Future<List<AlertEventRow>> evaluateAll({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final dayStart = DateTime(current.year, current.month, current.day);
    final dayEnd = DateTime(current.year, current.month, current.day + 1);

    final rules = (await _dao.getAlertRules()).where((r) => r.enabled).toList();
    if (rules.isEmpty) {
      await _dao.setSetting(lastCheckedKey, current.toIso8601String());
      return const [];
    }

    final holdings = await _dao.getHoldings();

    // FX rates so foreign-currency holdings are measured against the CNY
    // total (rule thresholds compare CNY-proportions).
    final currencies = holdings
        .map((h) => h.currency)
        .where((c) => c != 'CNY')
        .toSet()
        .toList();
    final cnyRates = currencies.isEmpty
        ? const <String, double>{}
        : await MarketService(_dao).loadCnyRates(currencies);

    // Resolve quotes by source and holding, including source-checked legacy rows.
    final cacheKeys = holdingQuoteCacheKeys(holdings);
    final cache = await _dao.getCachedPrices(cacheKeys);
    final prev = <int, double>{
      for (final h in holdings)
        if (cachedQuoteForHolding(cache, h)?.prevClose != null)
          h.id: cachedQuoteForHolding(cache, h)!.prevClose!,
    };

    final summary = const PortfolioCalculator().compute(
      holdings,
      prevPriceByHoldingId: prev,
      cnyRates: cnyRates,
    );
    final ctx = RuleContext(
      summary: summary,
      holdings: holdings,
      priceCache: cache,
      cnyRates: cnyRates,
      targetAllocation: parseTargetAllocation(
        await _dao.getSetting(targetAllocationKey),
      ),
      now: current,
    );

    final newEvents = <AlertEventRow>[];
    await _dao.transaction(() async {
      for (final rule in rules) {
        final evaluator = ruleEvaluators[AlertRuleType.fromStorage(rule.type)];
        if (evaluator == null) continue;
        final results = evaluator.evaluate(rule, ctx);
        final existing = await _dao.getAlertEventsForDay(
          rule.id,
          dayStart,
          dayEnd,
        );
        for (final result in results) {
          final duplicate = existing.any(
            (event) =>
                event.title == result.title &&
                (result.dedupPrefix == null ||
                    event.message.startsWith(result.dedupPrefix!)),
          );
          if (duplicate) continue;
          final event = await _dao.createAlertEvent(
            AlertEventsCompanion.insert(
              ruleId: rule.id,
              title: result.title,
              message: result.message,
              // Stamp the evaluated clock, not the column default. The default
              // records the *real* time, while the dedup window above is derived
              // from [current]; when a caller injects `now` (tests, and any
              // historical replay) the two disagree, the event lands outside its
              // own dedup window, and the same rule fires again for a day it has
              // already fired on.
              triggeredAt: Value(current),
            ),
          );
          final row = AlertEventRow(
            id: event,
            ruleId: rule.id,
            title: result.title,
            message: result.message,
            triggeredAt: current,
          );
          existing.add(row);
          newEvents.add(row);
        }
      }
      await _dao.setSetting(lastCheckedKey, current.toIso8601String());
    });
    return newEvents;
  }
}
