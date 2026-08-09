import 'package:drift/drift.dart';

import '../core/formats.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/portfolio_calculator.dart';
import 'market/market_service.dart';

/// Records one net-worth snapshot per day (per currency).
/// Called on app start / after refresh; idempotent for the same day.
/// Values are converted to CNY using current FX rates.
class SnapshotService {
  SnapshotService(
    this._dao, {
    DateTime Function()? clock,
    this._market,
  }) : _clock = clock ?? DateTime.now;

  final AssetDao _dao;
  final DateTime Function() _clock;
  final MarketService? _market;

  /// Ensures today's snapshot exists; recomputes it if the cached quote
  /// prices are newer than the snapshot's creation time.
  Future<void> ensureTodaySnapshot({bool force = false}) async {
    final now = _clock();
    final dateKey = todayKey(now);
    final existing = await _dao.getSnapshot(dateKey, 'CNY');
    if (existing != null && !force) return;

    final holdings = await _dao.getHoldings();
    // Convert non-CNY holdings with current FX rates so today's snapshot
    // matches the dashboard figures.
    final currencies =
        holdings.map((h) => h.currency).where((c) => c != 'CNY').toList();
    final rates = _market == null
        ? const <String, double>{}
        : await _market.loadCnyRates(currencies);
    final summary =
        const PortfolioCalculator().compute(holdings, cnyRates: rates);

    await _dao.upsertSnapshot(SnapshotsCompanion.insert(
      date: dateKey,
      currency: const Value('CNY'),
      totalValue: summary.netWorth,
      totalCost: summary.totalCost,
    ));
  }
}
