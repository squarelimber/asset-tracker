import '../core/enums.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/portfolio_calculator.dart';
import '../domain/rule_engine.dart';

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
    final symbols = holdings
        .map((h) => h.symbol)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
    final cache = await _dao.getCachedPrices(symbols);

    final summary = const PortfolioCalculator().compute(
      holdings,
      prevPriceBySymbol: {
        for (final e in cache.entries)
          if (e.value.prevClose != null) e.key: e.value.prevClose!,
      },
    );
    final ctx = RuleContext(
      summary: summary,
      holdings: holdings,
      priceCache: cache,
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
