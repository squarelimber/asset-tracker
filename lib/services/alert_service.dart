import '../core/enums.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/portfolio_calculator.dart';
import '../domain/rule_engine.dart';
import 'market/market_service.dart';

/// Runs all enabled alert rules, dedups by day, and persists fired events.
class AlertService {
  AlertService(this._dao);

  final AssetDao _dao;

  /// Evaluates all enabled rules. Returns events that are new (not fired
  /// today for the same rule+message).
  Future<List<AlertEventRow>> evaluateAll({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final dayStart = DateTime(current.year, current.month, current.day);

    final rules = (await _dao.getAlertRules()).where((r) => r.enabled).toList();
    if (rules.isEmpty) return const [];

    final holdings = await _dao.getHoldings();

    // FX rates so foreign-currency holdings are measured against the CNY
    // total (rule thresholds compare CNY-proportions).
    final currencies =
        holdings.map((h) => h.currency).where((c) => c != 'CNY').toSet().toList();
    final cnyRates = currencies.isEmpty
        ? const <String, double>{}
        : await MarketService(_dao).loadCnyRates(currencies);

    // Price cache keyed by the normalized cache symbol (cacheSymbolFor),
    // then mapped back to the holding's raw symbol for the calculator.
    final cacheKeys = [
      for (final h in holdings)
        if (cacheSymbolFor(h) != null) cacheSymbolFor(h)!,
    ];
    final cache = await _dao.getCachedPrices(cacheKeys);
    final prev = <String, double>{
      for (final h in holdings)
        if (h.symbol != null &&
            cache[cacheSymbolFor(h)]?.prevClose != null)
          h.symbol!: cache[cacheSymbolFor(h)]!.prevClose!,
    };

    final summary = const PortfolioCalculator().compute(
      holdings,
      prevPriceBySymbol: prev,
      cnyRates: cnyRates,
    );
    final ctx = RuleContext(
      summary: summary,
      holdings: holdings,
      priceCache: cache,
      cnyRates: cnyRates,
      now: current,
    );

    final newEvents = <AlertEventRow>[];
    for (final rule in rules) {
      final evaluator = ruleEvaluators[AlertRuleType.fromStorage(rule.type)];
      if (evaluator == null) continue;
      final results = evaluator.evaluate(rule, ctx);
      for (final result in results) {
        // Dedup: skip if the same rule already fired today with same title.
        final existing = await _dao.getRecentAlertEvent(rule.id, dayStart);
        if (existing != null && existing.title == result.title) continue;
        final event = await _dao.createAlertEvent(AlertEventsCompanion.insert(
          ruleId: rule.id,
          title: result.title,
          message: result.message,
        ));
        newEvents.add(AlertEventRow(
          id: event,
          ruleId: rule.id,
          title: result.title,
          message: result.message,
          triggeredAt: current,
        ));
      }
    }
    return newEvents;
  }
}
