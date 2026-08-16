import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/history_sync.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/holding_details.dart';
import '../domain/transaction_service.dart';
import '../services/history_backfill_service.dart';
import '../services/market/market_service.dart';
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

/// One-time per-session history sync marker (legacy rebuild trigger).
const historySyncV5Key = 'history_sync_v5';

/// Shared history sync: backfills historical snapshots when dirty (or on
/// the legacy first run) and refreshes today's snapshot, so the portfolio
/// page and the earnings calendar always agree. Runs once per session;
/// both pages watch it to trigger/refresh.
final historySyncProvider = FutureProvider<BackfillResult?>((ref) async {
  final dao = ref.read(daoProvider);
  final dirty = await dao.getSetting(historySyncDirtyKey);
  final firstRun = await dao.getSetting(historySyncV5Key) == null;
  final result = await ref.read(historyBackfillServiceProvider).backfill(
        forceRebuild: dirty == historyDirtySet || firstRun,
      );
  if (dirty == historyDirtySet) {
    await dao.setSetting(historySyncDirtyKey, historyDirtyClear);
  }
  if (firstRun) {
    await dao.setSetting(historySyncV5Key, '1');
  }
  // Refresh today's snapshot so the calendar's today matches the
  // dashboard's live summary.
  await ref.read(snapshotServiceProvider).ensureTodaySnapshot(force: true);
  return result;
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
  (ref) => ref.watch(daoProvider).watchSnapshots(),
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
