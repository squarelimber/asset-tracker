import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
import '../services/market/trading_calendar_service.dart';
import '../core/market_session.dart';
import '../services/product_earnings_service.dart';
import '../services/snapshot_service.dart';

/// App-wide database instance.
final databaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

/// Privacy toggle: hides monetary amounts on the portfolio page.
/// Defaults to hidden; resets on every launch (not persisted).
final hideAmountsProvider = StateProvider<bool>((ref) => true);

/// Identity of the installed build, e.g. `0.9.9+35`; `未知` when the platform
/// cannot report it. Shown in Settings → 关于 so a bug report can state exactly
/// which build it came from.
///
/// Read from the platform package instead of a compiled-in constant: a
/// constant would be a second source of truth for the version, free to drift
/// from what is actually installed.
final appVersionProvider = FutureProvider<String>((ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.buildNumber.isEmpty
        ? info.version
        : '${info.version}+${info.buildNumber}';
  } catch (_) {
    // No platform channel (widget tests) or no package metadata (a web host
    // that does not serve version.json): fall back instead of failing the
    // whole settings page.
    return '未知';
  }
});

/// Data access layer.
final daoProvider = Provider<AssetDao>(
  (ref) => AssetDao(ref.watch(databaseProvider)),
);

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

/// A-share trading-day calendar fetched from Eastmoney and installed into
/// the session helpers ([setLiveTradingDays]) so A-share session/holiday
/// decisions use the authoritative calendar (including 调休). Reads the
/// cached set immediately; re-fetches on the Dec 1 rollover (next year), when
/// the current year's entry is missing, or when the cache is not from today.
///
/// The installed set is paired with its coverage end ([coverageEndDay]) so a
/// calendar fetched *before* a later trading day cannot mark that day 休市.
final tradingCalendarProvider = FutureProvider<void>((ref) async {
  final calendar = TradingCalendarService(ref.watch(daoProvider));
  final now = DateTime.now();
  // Ensure this year's calendar is fetched/cached.
  await calendar.isTradingDay(now);
  // December rollover: pull next year now so it is ready on Jan 1.
  if (now.month == 12) {
    await calendar.isTradingDay(DateTime(now.year + 1, 1, 1));
  }
  final all = await calendar.allTradingDays();
  setLiveTradingDays(
    all.isEmpty ? null : all,
    coverageEnd: await calendar.coverageEndDay(),
  );
  return;
});

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

/// Per-holding (value, cost) on a given day, using the exact same snapshot
/// replay rules — the earnings-calendar day panel uses this so its per-product
/// sum equals the calendar cell (previously drifted via a separate
/// ProductEarningsService path).
final dayHoldingsBreakdownProvider = FutureProvider.autoDispose
    .family<List<DayHoldingValue>, DateTime>((ref, day) async {
      return ref.read(historyBackfillServiceProvider).dayHoldingsBreakdown(day);
    });

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
/// calendar's today cell. Null when today's snapshot is missing — see
/// [todayEarningOf], which refuses to relabel an earlier day's move as
/// today's.
final todayEarningProvider = Provider<({double profit, double? pct})?>((ref) {
  final list = ref.watch(snapshotsProvider).value;
  if (list == null) return null;
  return todayEarningOf(list, now: DateTime.now());
});

/// Emits whenever the history dirty flag flips (settings row watch), so
/// the history provider can rebuild in-session after a startup sync
/// merged source rows.
final historyDirtyFlagProvider = StreamProvider<String?>(
  (ref) => ref.watch(daoProvider).watchSetting(historySyncDirtyKey),
);

/// Shared history sync: backfills historical snapshots when dirty (or on
/// the legacy first run) and refreshes today's snapshot, so the portfolio
/// page and the earnings calendar always agree. Runs once per session;
/// both pages watch it to trigger/refresh.
final historySyncProvider = FutureProvider<BackfillResult?>((ref) async {
  final dao = ref.read(daoProvider);
  // Load the A-share trading calendar (Dec rollover included) so snapshot /
  // session decisions today use the authoritative holiday calendar.
  ref.watch(tradingCalendarProvider);
  // React to the dirty flag flipping: a startup auto-sync that merges
  // source rows sets it AFTER this provider may already have computed a
  // light pass — watching the flag rebuilds derived snapshots in-session.
  ref.watch(historyDirtyFlagProvider);
  final dirty = await dao.getSetting(historySyncDirtyKey);
  final firstRun = await dao.getSetting(historySyncV6Key) == null;
  // Refresh quotes FIRST so the backfill prices today from fresh quotes:
  // its today row then uses the exact same figures as the live dashboard.
  // (A failed refresh does not abort — the backfill falls back to the
  // cached quote / history series, and the fetch-failure abort below leaves
  // any pre-existing today row alone.)
  await ref.read(marketServiceProvider).refreshAll();
  final result = await ref
      .read(historyBackfillServiceProvider)
      .backfill(forceRebuild: dirty == historyDirtySet || firstRun);
  if (dirty == historyDirtySet) {
    await dao.setSetting(historySyncDirtyKey, historyDirtyClear);
  }
  if (firstRun) {
    await dao.setSetting(historySyncV6Key, '1');
  }
  // Today is covered by the backfill itself, with replay rules identical to
  // every earlier day (today priced at the refreshed live quote), so its
  // cost basis is the SAME as yesterday's — the calendar and the per-product
  // day panel cannot drift apart. Overwriting today afterwards with
  // PortfolioCalculator (quantity × current costPrice) gave today a DIFFERENT
  // cost basis than yesterday (the −863/−883 phantom: backfill cost 2,257,903
  // on 10/1 vs live cost 2,258,766 on 10/2).
  //
  // Skipped when the run was aborted because a price history could not be
  // fetched: in that state the quotes behind today's figures are not
  // trustworthy either, and rewriting the day would overwrite whatever was
  // already recorded with a stale derivation.
  //
  // SnapshotService remains the fallback ONLY when the backfill could not
  // write today (web / history fetch unavailable).
  if (!result.historyUnavailable && !result.wroteToday) {
    await ref.read(snapshotServiceProvider).ensureTodaySnapshot(force: true);
  }
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
      return ref
          .watch(productEarningsServiceProvider)
          .compute(from: from, to: to);
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
final priceCacheProvider = FutureProvider<Map<String, PriceCacheRow>>((
  ref,
) async {
  final holdings = await ref.watch(holdingsProvider.future);
  final symbols = holdings
      .map(cacheSymbolFor)
      .whereType<String>()
      .toSet()
      .toList();
  return ref.read(daoProvider).getCachedPrices(symbols);
});

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

final transactionsProvider = StreamProvider<List<TransactionRow>>(
  (ref) => ref.watch(daoProvider).watchTransactions(),
);

final transactionsByAccountProvider =
    StreamProvider.family<List<TransactionRow>, int>(
      (ref, accountId) =>
          ref.watch(daoProvider).watchTransactionsByAccount(accountId),
    );

final transactionsByHoldingProvider =
    StreamProvider.family<List<TransactionRow>, int>(
      (ref, holdingId) =>
          ref.watch(daoProvider).watchTransactionsByHolding(holdingId),
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
