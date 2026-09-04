import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/history_sync.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/daily_earnings.dart';
import '../domain/holding_details.dart';
import '../domain/product_monthly_earnings.dart';
import '../domain/transaction_service.dart';
import '../services/alert_notification_service.dart';
import '../services/history_backfill_service.dart';
import '../services/notification_service.dart';
import '../services/market/market_service.dart';
import '../services/product_earnings_service.dart';
import '../services/snapshot_service.dart';

/// App-wide database instance.
final databaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

/// Privacy toggle: hides monetary amounts on the portfolio page.
/// Defaults to hidden; resets on every launch (not persisted).
final hideAmountsProvider = StateProvider<bool>((ref) => true);

/// Data access layer.
final daoProvider = Provider<AssetDao>((ref) => AssetDao(ref.watch(databaseProvider)));

/// Transaction recording / linkage engine.
final transactionServiceProvider = Provider<TransactionService>(
  (ref) => TransactionService(ref.watch(daoProvider)),
);

/// Per-day holding breakdown for the trend chart tap detail.
final holdingDetailServiceProvider = Provider<HoldingDetailService>(
  (ref) => HoldingDetailService(ref.watch(daoProvider)),
);

/// CNY per unit for every non-CNY currency used by any holding.
/// Refreshed on each market refresh (see portfolio/holdings pages).
final cnyRatesProvider = FutureProvider<Map<String, double>>((ref) async {
  final holdings = await ref.watch(holdingsProvider.future);
  final currencies = holdings
      .map((h) => h.currency)
      .where((c) => c != 'CNY')
      .toList();
  return ref.read(marketServiceProvider).loadCnyRates(currencies);
});

/// Market data orchestration engine.
final marketServiceProvider = Provider<MarketService>(
  (ref) => MarketService(ref.watch(daoProvider)),
);

/// Local notification wrapper. Shared singleton (see notification_service.dart):
/// re-initializing the plugin would re-trigger the Android permission prompt.
final notificationServiceProvider = Provider<NotificationService>(
  (ref) => notificationService,
);

/// Evaluates alert rules and shows a local notification per new event.
final alertNotificationServiceProvider = Provider<AlertNotificationService>(
  (ref) => AlertNotificationService(
    ref.watch(daoProvider),
    ref.watch(notificationServiceProvider),
  ),
);

/// Historical net worth backfill engine.
final historyBackfillServiceProvider = Provider<HistoryBackfillService>(
  (ref) => HistoryBackfillService(
    ref.watch(daoProvider),
    market: ref.watch(marketServiceProvider),
  ),
);

/// Records one net-worth snapshot per day.
final snapshotServiceProvider = Provider<SnapshotService>(
  (ref) => SnapshotService(
    ref.watch(daoProvider),
    market: ref.watch(marketServiceProvider),
  ),
);

/// One-time per-session history sync marker. Bumped to v6 to force a full
/// snapshot rebuild once after the sync-repayment bug fix, so already
/// corrupted devices regenerate their derived snapshots.
const historySyncV6Key = 'history_sync_v6';

/// Today's earning in the snapshot (calendar) view: today's snapshot
/// profit (value - cost) minus yesterday's, matching the earnings
/// calendar's today cell. Null when snapshots are unavailable.
final todayEarningProvider =
    Provider<({double profit, double? pct})?>((ref) {
  final list = ref.watch(snapshotsProvider).value;
  if (list == null) return null;
  return todayEarningOf(list);
});

/// Shared history sync: backfills historical snapshots when dirty (or on
/// the legacy first run) and refreshes today's snapshot, so the portfolio
/// page and the earnings calendar always agree. Runs once per session;
/// both pages watch it to trigger/refresh.
final historySyncProvider = FutureProvider<BackfillResult?>((ref) async {
  final dao = ref.read(daoProvider);
  final dirty = await dao.getSetting(historySyncDirtyKey);
  final firstRun = await dao.getSetting(historySyncV6Key) == null;
  final result = await ref.read(historyBackfillServiceProvider).backfill(
        forceRebuild: dirty == historyDirtySet || firstRun,
      );
  if (dirty == historyDirtySet) {
    await dao.setSetting(historySyncDirtyKey, historyDirtyClear);
  }
  if (firstRun) {
    await dao.setSetting(historySyncV6Key, '1');
  }
  // Refresh today's snapshot so the calendar's today matches the
  // dashboard's live summary.
  await ref.read(snapshotServiceProvider).ensureTodaySnapshot(force: true);
  return result;
});

/// Per-product monthly earnings engine (sold-out products included via
/// flow replay).
final productEarningsServiceProvider = Provider<ProductEarningsService>(
  (ref) => ProductEarningsService(
    ref.watch(daoProvider),
    market: ref.watch(marketServiceProvider),
  ),
);

/// Per-product earnings for [year]: window from the first day of the
/// previous month of (year-1) to the end of [year] (or today for the
/// current year), so every month of [year] has a baseline day. Month and
/// year navigation on the page is client-side over this result.
final productEarningsProvider = FutureProvider.autoDispose
    .family<List<ProductEarnings>, int>((ref, year) async {
  ref.watch(historySyncProvider);
  final now = DateTime.now();
  final from = DateTime(year - 1, 12, 1);
  final to = year < now.year
      ? DateTime(year, 12, 31)
      : DateTime(now.year, now.month, now.day);
  return ref.watch(productEarningsServiceProvider).compute(from: from, to: to);
});

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

final accountsProvider = StreamProvider<List<AccountRow>>(
  (ref) => ref.watch(daoProvider).watchAccounts(),
);

final accountProvider = FutureProvider.family<AccountRow?, int>(
  (ref, id) => ref.watch(daoProvider).getAccount(id),
);

// ---------------------------------------------------------------------------
// Holdings
// ---------------------------------------------------------------------------

final holdingsProvider = StreamProvider<List<HoldingRow>>(
  (ref) => ref.watch(daoProvider).watchHoldings(),
);

final holdingsByAccountProvider = StreamProvider.family<List<HoldingRow>, int>(
  (ref, accountId) => ref.watch(daoProvider).watchHoldingsByAccount(accountId),
);

// ---------------------------------------------------------------------------
// Price cache (today's change for each holding's quote)
// ---------------------------------------------------------------------------

/// Cached quotes by normalized cache symbol, keyed the same way
/// `MarketService` writes them. Invalidated after every market refresh.
final priceCacheProvider = FutureProvider<Map<String, PriceCacheRow>>(
  (ref) async {
    final holdings = await ref.watch(holdingsProvider.future);
    final symbols = holdings
        .map(cacheSymbolFor)
        .whereType<String>()
        .toSet()
        .toList();
    return ref.read(daoProvider).getCachedPrices(symbols);
  },
);

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

final transactionsProvider = StreamProvider<List<TransactionRow>>(
  (ref) => ref.watch(daoProvider).watchTransactions(),
);

final transactionsByAccountProvider = StreamProvider.family<List<TransactionRow>, int>(
  (ref, accountId) => ref.watch(daoProvider).watchTransactionsByAccount(accountId),
);

final transactionsByHoldingProvider = StreamProvider.family<List<TransactionRow>, int>(
  (ref, holdingId) => ref.watch(daoProvider).watchTransactionsByHolding(holdingId),
);

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

final snapshotsProvider = StreamProvider<List<SnapshotRow>>(
  // Snapshots are always recorded in CNY (values are CNY-converted); filter
  // to a single currency so today's earning and the calendar never see a
  // stray foreign-currency row that would shift the last/last-1 baseline.
  (ref) => ref.watch(daoProvider).watchSnapshots(currency: 'CNY'),
);

// ---------------------------------------------------------------------------
// Alert rules
// ---------------------------------------------------------------------------

final alertRulesProvider = StreamProvider<List<AlertRuleRow>>(
  (ref) => ref.watch(daoProvider).watchAlertRules(),
);

final alertEventsProvider = StreamProvider<List<AlertEventRow>>(
  (ref) => ref.watch(daoProvider).watchRecentAlertEvents(),
);
