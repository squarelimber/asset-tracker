import '../core/formats.dart';
import '../data/database.dart';
import 'daily_earnings.dart';
import 'holding_valuation.dart';
import 'transaction_identity.dart';

/// Synced, fully rebuilt snapshots may already cover the ledger even while
/// the local history-dirty flag remains set (notably on web clients, which
/// cannot run a native rebuild). Check the actual window used by the risk
/// estimate before bypassing that flag; never clear the flag itself here.
bool riskHistoryCoversLedger(
  List<SnapshotRow> snapshots,
  List<HoldingRow> holdings,
  List<TransactionRow> transactions,
  List<SyncTombstoneRow> tombstones, {
  DateTime? now,
}) {
  final today = todayKey(now ?? DateTime.now());
  final ordered =
      snapshots
          .where(
            (snapshot) =>
                snapshot.currency.toUpperCase() == 'CNY' &&
                snapshot.date.compareTo(today) < 0,
          )
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));
  if (ordered.length < 2) return false;
  final window = ordered.length > 366
      ? ordered.sublist(ordered.length - 366)
      : ordered;
  DateTime? latestChange;
  void include(DateTime changedAt) {
    if (latestChange == null || changedAt.isAfter(latestChange!)) {
      latestChange = changedAt;
    }
  }

  for (final holding in holdings) {
    include(holding.updatedAt);
  }
  for (final transaction in transactions) {
    include(transaction.historyUpdatedAt);
  }
  for (final tombstone in tombstones) {
    if (const {
      'holdings',
      'transactions',
      'accounts',
    }.contains(tombstone.table)) {
      include(tombstone.deletedAt);
    }
  }
  return window.every(
    (snapshot) =>
        snapshotCalendarDate(snapshot.date) != null &&
        snapshot.profitAdjustment != null &&
        snapshotHoldingValues(snapshot) != null &&
        (latestChange == null || !snapshot.createdAt.isBefore(latestChange!)),
  );
}
