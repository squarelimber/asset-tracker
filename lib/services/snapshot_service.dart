import 'package:drift/drift.dart';

import '../core/formats.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/portfolio_calculator.dart';
/// Records one net-worth snapshot per day (per currency).
/// Called on app start / after refresh; idempotent for the same day.
class SnapshotService {
  SnapshotService(this._dao, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final AssetDao _dao;
  final DateTime Function() _clock;

  /// Ensures today's snapshot exists; recomputes it if the cached quote
  /// prices are newer than the snapshot's creation time.
  Future<void> ensureTodaySnapshot({bool force = false}) async {
    final now = _clock();
    final dateKey = todayKey(now);
    final existing = await _dao.getSnapshot(dateKey, 'CNY');
    if (existing != null && !force) return;

    final holdings = await _dao.getHoldings();
    final summary = const PortfolioCalculator().compute(holdings);

    await _dao.upsertSnapshot(SnapshotsCompanion.insert(
      date: dateKey,
      currency: const Value('CNY'),
      totalValue: summary.netWorth,
      totalCost: summary.totalCost,
    ));
  }
}
