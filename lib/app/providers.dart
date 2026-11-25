import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/history_sync.dart';
import '../core/formats.dart';
import '../core/symbols.dart';
import '../core/ui_prefs.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/daily_earnings.dart';
import '../domain/earnings_breakdown.dart';
import '../domain/external_sale_gains.dart';
import '../domain/holding_valuation.dart';
import '../domain/holding_details.dart';
import '../domain/product_monthly_earnings.dart';
import '../domain/transaction_service.dart';
import '../domain/transaction_identity.dart';
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

/// Current session's privacy toggle. The app entry point initializes it from
/// the saved startup preference, while the eye button only affects the session.
final hideAmountsProvider = StateProvider<bool>((ref) => true);

final hideAmountsOnStartupProvider = StreamProvider<bool>((ref) {
  return ref
      .watch(daoProvider)
      .watchSetting(hideAmountsOnStartupKey)
      .map((value) => value == 'true');
});

/// 总览页焦点滚轮卡的每面停留时长（毫秒），存在 settings 表里。
///
/// 与 [hideAmountsProvider] 不同，这一项是**持久化**的：卡片节奏是偏好而
/// 非临时开关，重启后应当记住。脏值（0 / 负数 / 非数字）一律回退默认 ——
/// 0 会让卡片每帧都排一次翻转，疯狂打转。
final spotlightHoldMsProvider = StreamProvider<int>((ref) {
  return ref.watch(daoProvider).watchSetting(spotlightHoldMsKey).map((raw) {
    final ms = int.tryParse(raw ?? '');
    return (ms != null && ms > 0) ? ms : defaultSpotlightHoldMs;
  }).distinct();
});

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

/// Ledger currencies may outlive the holdings using them.
final transactionCnyRatesProvider = FutureProvider<Map<String, double>>((
  ref,
) async {
  final txns = ref.watch(transactionsProvider.future);
  final holdingRates = ref.watch(cnyRatesProvider.future);
  final market = ref.watch(marketServiceProvider);
  final currencies = (await txns)
      .map((row) => row.currency.toUpperCase())
      .toSet();
  final rates = Map<String, double>.of(await holdingRates);
  final missing = currencies.where((code) {
    final rate = rates[code];
    return code != 'CNY' && (rate == null || !rate.isFinite || rate <= 0);
  }).toList();
  if (missing.isNotEmpty) {
    rates.addAll(await market.loadCnyRates(missing));
  }
  return rates;
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
/// Coverage stops at the newest observed trading day, so a pre-open fetch
/// cannot mark today's still-unpublished session as 休市.
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
  setLiveTradingDays(all.isEmpty ? null : all);
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

/// Per-holding values recorded with the day's aggregate snapshot. Missing or
/// invalid historical detail stays unavailable instead of being revalued.
final dayHoldingsBreakdownProvider = FutureProvider.autoDispose
    .family<List<DayHoldingValue>, DateTime>((ref, day) async {
      final snapshots = await ref.watch(snapshotsProvider.future);
      final snapshot = snapshots
          .where((s) => s.date == todayKey(day))
          .firstOrNull;
      if (snapshot == null) return const [];
      return snapshotHoldingValues(snapshot) ?? const [];
    });

final dailyEarningsProvider = FutureProvider<List<DailyEarning>>((ref) async {
  final snapshots = await ref.watch(snapshotsProvider.future);
  return const DailyEarningsCalculator().compute(snapshots);
});

final earningsBreakdownProvider = FutureProvider.autoDispose
    .family<EarningsBreakdown, DateTime>((ref, day) async {
      final snapshotsFuture = ref.watch(snapshotsProvider.future);
      final transactionsFuture = ref.watch(transactionsProvider.future);
      final snapshots = await snapshotsFuture;
      final transactions = await transactionsFuture;
      return earningsBreakdownOf(
        snapshots,
        todayKey(day),
        transactions: transactions,
      );
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
final todayEarningProvider =
    Provider<({double profit, double? pct, DateTime updatedAt})?>((ref) {
      final list = ref.watch(snapshotsProvider).value;
      if (list == null) return null;
      final value = todayEarningOf(list, now: DateTime.now());
      return value == null
          ? null
          : (
              profit: value.profit,
              pct: value.pct,
              updatedAt: list.last.createdAt,
            );
    });

/// Emits whenever the history dirty flag flips (settings row watch), so
/// the history provider can rebuild in-session after a startup sync
/// merged source rows.
final historyDirtyFlagProvider = StreamProvider<String?>(
  (ref) => ref.watch(daoProvider).watchSetting(historySyncDirtyKey),
);

final historyFullRebuildFlagProvider = StreamProvider<String?>(
  (ref) => ref.watch(daoProvider).watchSetting(historyFullRebuildKey),
);

/// Deletions also invalidate risk history after their source row is gone.
final riskHistoryTombstonesProvider = StreamProvider<List<SyncTombstoneRow>>(
  (ref) => ref.watch(daoProvider).watchTombstones(),
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
  final market = ref.read(marketServiceProvider);
  final backfill = ref.read(historyBackfillServiceProvider);
  final snapshots = ref.read(snapshotServiceProvider);
  final dirty = await dao.getSetting(historySyncDirtyKey);
  final firstRun = await dao.getSetting(historySyncV6Key) == null;
  // Refresh quotes FIRST so the backfill prices today from fresh quotes:
  // its today row then uses the exact same figures as the live dashboard.
  // (A failed refresh does not abort — the backfill falls back to the
  // cached quote / history series, and the fetch-failure abort below leaves
  // any pre-existing today row alone.)
  await market.refreshAll();
  var result = await backfill.backfill(
    forceRebuild: dirty == historyDirtySet || firstRun,
  );
  if (result.inputsChanged) {
    result = await backfill.backfill(forceRebuild: true);
  }
  if (result.ok && firstRun) {
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
    await snapshots.ensureTodaySnapshot(force: true);
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

/// Per-product earnings through [year], with the prior baseline retained.
final _productEarningsInputsProvider = FutureProvider.autoDispose.family((
  ref,
  int year,
) async {
  ref.watch(historySyncProvider);
  final snapshots = ref.watch(snapshotsProvider.future);
  final transactions = ref.watch(transactionsProvider.future);
  final end = '$year-12-31';
  final observed = await snapshots;
  return (
    snapshots: observed.where((s) => s.date.compareTo(end) <= 0).toList(),
    nextSnapshot: observed.where((s) => s.date.compareTo(end) > 0).firstOrNull,
    transactions: await transactions,
  );
});

final productEarningsProvider = FutureProvider.autoDispose
    .family<List<ProductEarnings>, int>((ref, year) async {
      final inputs = await ref.watch(
        _productEarningsInputsProvider(year).future,
      );
      return productsFromSnapshots(
        inputs.snapshots,
        transactions: inputs.transactions,
        attributionRequiredFrom: '$year-01-01',
      );
    });

final productEarningsReportProvider = FutureProvider.autoDispose
    .family<ProductEarningsReport, int>((ref, year) async {
      final inputs = await ref.watch(
        _productEarningsInputsProvider(year).future,
      );
      final issues = <EarningsAttributionIssue>[];
      final products = productsFromSnapshots(
        inputs.snapshots,
        transactions: inputs.transactions,
        attributionRequiredFrom: '$year-01-01',
        onIssue: issues.add,
      );
      const calculator = DailyEarningsCalculator();
      final earnings = calculator.compute([
        ...inputs.snapshots,
        ?inputs.nextSnapshot,
      ]);
      for (var month = 1; month <= 12; month++) {
        if (calculator.monthOf(earnings, year, month).hasUnallocatedProfit) {
          issues.add(
            EarningsAttributionIssue(
              date: todayKey(DateTime(year, month)),
              message: '快照断档横跨月份，暂不能把区间收益拆分到本月。',
              canRebuild: true,
            ),
          );
        }
      }
      issues.sort((a, b) => b.date.compareTo(a.date));
      return ProductEarningsReport(products, issues: issues);
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

/// Cached quotes by source and normalized symbol, plus compatible legacy rows.
/// Invalidated after every market refresh.
final priceCacheProvider = FutureProvider<Map<String, PriceCacheRow>>((
  ref,
) async {
  final holdings = await ref.watch(holdingsProvider.future);
  final symbols = holdingQuoteCacheKeys(holdings).toSet().toList();
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
  (ref) {
    final stream = ref.watch(daoProvider).watchSnapshots(currency: 'CNY');
    final transactions = ref.watch(transactionsProvider).valueOrNull;
    if (transactions == null || !transactions.any(isExternalSale)) {
      return stream;
    }
    final holdings = ref.watch(holdingsProvider).valueOrNull;
    if (holdings == null) return stream;
    final rates =
        transactions.any((t) => isExternalSale(t) && t.currency != 'CNY')
        ? ref.watch(cnyRatesProvider).valueOrNull ?? const <String, double>{}
        : const <String, double>{};
    return stream.map(
      (rows) =>
          ExternalSaleGains(holdings, transactions, rates).fillLegacy(rows),
    );
  },
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
