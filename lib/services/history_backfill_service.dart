import 'package:flutter/foundation.dart' show kIsWeb;

import '../core/enums.dart';
import '../core/formats.dart';
import '../core/history_sync.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/holding_cost.dart';
import '../domain/product_monthly_earnings.dart';
import '../domain/smooth_history.dart';
import 'market/history_lookup.dart';
import 'market/history_source.dart';
import 'market/market_service.dart';
import 'market/tencent_history_source.dart';

/// Result of a history backfill run.
class BackfillResult {
  const BackfillResult({
    required this.ok,
    required this.days,
    required this.holdings,
    this.message,
    this.historyUnavailable = false,
    this.wroteToday = false,
  });

  final bool ok;
  final int days;
  final int holdings;
  final String? message;

  /// True when the run was aborted because one or more holding price
  /// histories could not be fetched. Callers must not treat this as a
  /// harmless "nothing to do": in this state no snapshot was written, so
  /// derived figures must not be rewritten from the current (possibly
  /// stale) quotes either.
  final bool historyUnavailable;

  /// True when this run wrote a row for today by re-deriving it from the
  /// same price series as every earlier day. Callers may then skip the
  /// live-quote fallback writer: that writer rebuilds today from whatever
  /// quotes happen to be cached, and [SnapshotService.ensureTodaySnapshot]
  /// documents that it must only be forced once those quotes are known to
  /// be fresh — which this code path cannot promise (no refresh has run).
  final bool wroteToday;
}

/// Backfills historical daily net-worth snapshots from each holding's
/// purchase date onward, so the net worth chart shows the full holding
/// period even for assets bought long before the app was first used.
///
/// Data sources:
/// - Mutual funds: Eastmoney NAV history
/// - Stocks / ETFs / LOFs: Sina daily K-line
/// - Gold accumulation: London spot gold history converted to CNY/gram
///   (the same instrument and conversion as the live gold quote)
/// Manual-NAV assets (bank wealth etc.) are carried at their latest price
/// across the backfill window (they only change when the user updates them).
///
/// The window **includes today**. Today used to be excluded (the loop
/// stopped before `todayDate`) and written by a separate live-quote path
/// instead, which meant any disagreement between the two valuation paths
/// landed on exactly one day — today — and showed up as a large fake daily
/// return. Re-deriving today from the same series makes the two paths agree
/// by construction: the last day of the rebuild and the day before it are
/// computed by one code path.
///
/// A light run also re-derives **every day since the previous run**, not
/// just today. The live path writes each day from intraday quotes, and a
/// day frozen that way is only repaired by re-deriving it from the
/// historical series; recomputing today alone left the previously frozen
/// day in place forever, so its inflated close-to-close baseline kept
/// understating the *next* day's return on every subsequent device (the
/// 2026-09-15 → 2026-09-16 "today's earning is far too small" bug: the day
/// before was written at 13:45 and never revisited). The window is
/// anchored to [_lastRunKey] rather than a fixed "today + yesterday", so a
/// gap of any length (app not opened for a while) is fully repaired too. On
/// the first run after this window shipped the anchor does not exist yet, so
/// the window falls back to [_firstRunLookbackDays] — see that constant.
///
/// Recomputation is atomic: new snapshots are fully computed first, then
/// swapped in a single transaction. The UI therefore never shows a gap
/// while the rebuild is running.
class HistoryBackfillService {
  HistoryBackfillService(
    this._dao, {
    Map<MarketSource, HistoryDataSource>? sources,
    MarketService? market,
  }) : _sources =
           sources ??
           {
             MarketSource.eastmoney: EastmoneyHistorySource(),
             // Tencent qfq (adjusted) klines keep unit splits/ex-rights
             // continuous over time, so backfilled history has no jumps.
             MarketSource.sina: TencentHistorySource(),
             MarketSource.sge: XauGoldHistorySource(),
           } {
    _market = market;
  }

  final AssetDao _dao;
  final Map<MarketSource, HistoryDataSource> _sources;
  MarketService? _market;

  /// Marker for the latest one-time full recompute. v5 replayed the cost
  /// principal (repayment/borrowing no longer leaks into the daily
  /// return); v6 extends the smoothed set to manually priced share assets
  /// (bond/futures/property) and FX-linked bank wealth, so the whole
  /// window is rebuilt once with the new interpolation semantics.
  /// v7 rebuilds once more for the gold instrument fix (London spot instead
  /// of the Shanghai futures contract) and for including today in the
  /// window — devices that already ran v6 hold gold history derived from
  /// the other instrument and need the corrected series.
  static const _backfillV3Marker = 'backfill_v7_gold_spot_and_today';

  /// Marker for the v8 one-time full rebuild: share-based holdings started
  /// being valued by replaying their buy/sell/split/dividend flows (HoldingReplay)
  /// instead of carrying the current quantity over every historical day — so
  /// sold-out and partially-sold positions finally show their real market
  /// value on the days they were held. Devices that already ran v7 hold
  /// history built with the current-quantity shortcut and need a full pass.
  static const _shareReplayMarker = 'backfill_v8_share_replay';

  /// Marker for the v9 one-time full rebuild: the v8 replay covered the
  /// market-linked share holdings, but **smoothed** share-based holdings
  /// (manual-NAV bank wealth, FX-linked bank wealth, etc.) were still valued
  /// with the *current* quantity on every historical day. After a partial
  /// redemption (e.g. 2026-09-24 月月宝 redeemed 107k of 223k shares) a full
  /// rebuild collapsed every day before the redemption by the redeemed market
  /// value, destroying the whole trend. v9 replays their flows too.
  static const _smoothShareReplayMarker = 'backfill_v9_smooth_share_replay';

  /// Marker for the v10 one-time full rebuild: the Sina/ETF history endpoint
  /// (`web.ifzq.gtimg.cn/.../fqkline/get`) started answering a WAF 501, which
  /// [TencentHistorySource] folded into an empty series. Because an empty
  /// series was not treated as a failure, every day re-derived for those
  /// holdings was priced from the *current* quote, so a whole window (e.g.
  /// 国庆 10-01..10-08, no trading days in between) came out flat at today's
  /// prices and the period's real move landed on the window's first day —
  /// the 2026-10-08「今天的收益被算到 10-05」report. The endpoint is fixed
  /// and an empty series now aborts, but the days written while it was broken
  /// are still flat and a light run never revisits them, so every device
  /// rebuilds the whole window once.
  static const _sinaHistoryEndpointMarker = 'backfill_v10_sina_history_endpoint';

  /// Marker for the v11 one-time full rebuild: the Tencent history gateway
  /// moved again. The v10 fix pointed [TencentHistorySource] at the bare
  /// `ifzq.gtimg.cn` host once `web.ifzq.gtimg.cn` began answering a WAF 501,
  /// but on 2026-10-09 the WAF had caught up with the bare host too and *both*
  /// returned 501 — so every ETF/stock/gold holding fetched an empty series,
  /// the rebuild aborted, and the net-worth curve was left with no history at
  /// all. The source now queries the `proxy.finance.qq.com` gateway. Any day
  /// written while both hosts were blocked is missing or flat and a light run
  /// never revisits it, so every device rebuilds the whole window once.
  static const _tencentGatewayMarker = 'backfill_v11_tencent_history_gateway';

  /// Date (yyyy-MM-dd) of the previous successful run. A light run re-derives
  /// every day from this date through today, because any of them may have
  /// been overwritten by the live-quote path in the meantime and needs to be
  /// put back on the historical series.
  static const _lastRunKey = 'backfill_last_run';

  /// How far back a light run reaches when [_lastRunKey] is absent — the
  /// first launch after this window shipped, or after a restore that dropped
  /// the setting. Defaulting to "today only" would leave a day the live path
  /// froze on intraday quotes permanently wrong, which is exactly the bug the
  /// window exists to repair; the devices installing this build are the ones
  /// most likely to be carrying such a day. Seven days covers a weekend plus
  /// holidays, and a longer backfill is cheap (one day-by-day pass over the
  /// same price series).
  static const _firstRunLookbackDays = 7;

  /// How long after its purchase date a holding still counts as *new*.
  ///
  /// A brand-new holding may legitimately have no price series yet (a fund
  /// whose NAV has not been published, a code the source does not know). Its
  /// days are then carried at the latest price — which for such a holding is
  /// today's quote and close enough to every day it has existed — so the
  /// rebuild must not abort over it. Once a holding is older than this, an
  /// empty series means the whole window would be valued from the current
  /// quote, which is the corruption the abort exists to prevent.
  static const _newHoldingGraceDays = 7;

  /// Backfills snapshots for dates before today.
  ///
  /// By default only missing days are filled. With [forceRebuild], the whole
  /// window (including already-snapshot days) is recomputed and overwritten,
  /// which merges newly added / edited / removed holdings into the history.
  Future<BackfillResult> backfill({
    DateTime? now,
    bool forceRebuild = false,
  }) async {
    // The Sina/Eastmoney history endpoints have no CORS support; the web
    // build cannot backfill history. Use the desktop/mobile app for this.
    if (kIsWeb) {
      return const BackfillResult(
        ok: false,
        days: 0,
        holdings: 0,
        message: '网页版暂不支持历史回填，请使用桌面版',
      );
    }
    final current = (now ?? DateTime.now());
    final todayDate = DateTime(current.year, current.month, current.day);

    final holdings = await _dao.getHoldings();
    if (holdings.isEmpty) {
      return const BackfillResult(
        ok: false,
        days: 0,
        holdings: 0,
        message: '暂无持仓',
      );
    }

    // Earliest purchase date across holdings defines the window start.
    DateTime? earliest;
    for (final h in holdings) {
      final d = h.purchaseDate ?? h.createdAt;
      if (earliest == null || d.isBefore(earliest)) earliest = d;
    }
    if (earliest == null) {
      return const BackfillResult(ok: false, days: 0, holdings: 0);
    }
    final windowStart = earliest;

    // Current FX rates for converting foreign-currency holdings to CNY
    // (market value uses the current rate; cost uses the recorded purchase
    // rate when available). Historical daily rates are approximated with
    // the current rate.
    final currencies = holdings
        .where((h) => h.currency != 'CNY' && !isFxLinked(h))
        .map((h) => h.currency)
        .toSet()
        .toList();
    final market = _market;
    final cnyRates = market == null
        ? const <String, double>{}
        : await market.loadCnyRates(currencies);
    // Same reasoning as the daily snapshot writer: `valueRateOf` falls back
    // to 1 for a code it cannot convert, so a missing rate would value that
    // holding at parity for *every* day of the rebuild — writing an entire
    // history that understates net worth by the FX leg. Abort before the
    // snapshots table is touched.
    final missingRates = missingCnyRates(currencies, cnyRates);
    if (missingRates.isNotEmpty) {
      return BackfillResult(
        ok: false,
        days: 0,
        holdings: 0,
        historyUnavailable: true,
        message:
            '缺少汇率（${missingRates.join('、')}），本次未写入任何快照，'
            '请检查网络后重试',
      );
    }

    // Fetch history per holding (in parallel). Holdings without a market
    // source (bank wealth, cash management) get a smooth interpolated
    // history instead of a fetched price series.
    final smoothCalc = const SmoothHistoryCalculator();
    final smoothValues = <int, Map<String, double>>{};
    final smoothPrincipals = <int, Map<String, double>>{};
    final fillers = <int, HistoryPriceLookup>{};
    // Share-based holdings: daily (quantity, totalCost) replayed from their
    // buy/sell/split/dividend flows, so sold-out / partially-sold positions
    // carry real market value on the days they were actually held (v8).
    final replays = <int, Map<String, (double, double)>>{};
    final futures = <Future<void>>[];
    // Symbols whose history fetch threw. A network failure must NOT be
    // silently swallowed: the day-by-day loop would otherwise fall back to
    // the *current* latest price for every historical date of that holding,
    // corrupting the whole net-worth history (seen 2026-09-04: a bad network
    // on fetch day produced a truncated/failed series and the snapshots for
    // 2020-08..2026-09 came out wrong). We collect failures and abort below
    // instead of writing bad rows.
    final failedSymbols = <String>[];
    // Transaction id -> sold principal (quantity x unit cost at sale time),
    // captured from every share-based holding's replay. A selling holding's
    // proceeds credited to a cash account must move the cash principal by
    // this number (not the full amount) so the sold gain stays a cash-side
    // unrealized gain — mirrors TransactionService._applySell.
    //
    // Phase 1 runs in two passes: every share-based replay first (so the
    // captured sell principals are complete *before* any amount-based cash
    // account derives its principal), then the cash smooth computation.
    final soldPrincipalById = <int, double>{};
    // Share-based smoothed (manual-NAV) holdings, replayed in phase 1.
    final smoothShareFlows = <int, List<TransactionRow>>{};
    for (final h in holdings) {
      final type = AssetType.fromStorage(h.assetType);
      if (isSmoothedHolding(h) && !type.isAmountBased) {
        final flows = await _dao.getTransactionsForHolding(h.id);
        smoothShareFlows[h.id] = flows;
        // Share-based smoothed holdings (manual-NAV / FX-linked bank
        // wealth) must replay their flows just like market-linked ones:
        // pricing every historical day with the *current* quantity makes a
        // full rebuild collapse the whole trend after a partial redemption
        // (2026-09-24「月月宝 → 五年国债ETF」report — the redeemed ~107k of
        // 223k shares vanished from every pre-redemption day).
        replays[h.id] = const HoldingReplay().replay(
          h,
          flows,
          from: windowStart,
          to: current,
          capturedSellPrincipal: soldPrincipalById,
        );
        continue;
      }
      if (isSmoothedHolding(h)) continue; // amount-based cash: phase 2
      final source = MarketSource.fromStorage(h.marketSource);
      final adapter = _sources[source];
      if (adapter == null) continue;
      var rawSymbol = (h.symbol != null && h.symbol!.isNotEmpty)
          ? h.symbol!
          : type.defaultSymbol;
      if (rawSymbol == null) continue;
      if (source == MarketSource.sina) {
        rawSymbol = normalizeSinaSymbol(rawSymbol);
      }
      final symbol = rawSymbol;
      // Replay the holding's own flows for its historical quantity/cost.
      final flows = await _dao.getTransactionsForHolding(h.id);
      replays[h.id] = const HoldingReplay().replay(
        h,
        flows,
        from: windowStart,
        to: current,
        capturedSellPrincipal: soldPrincipalById,
      );
      final buy = h.purchaseDate ?? h.createdAt;
      final buyDay = DateTime(buy.year, buy.month, buy.day);
      futures.add(() async {
        try {
          final history = await adapter.fetch(symbol, windowStart, current);
          if (history.isEmpty) {
            // An empty series is the second half of the 2026-10-08 bug: the
            // source answered (so nothing threw) but carried no rows, and the
            // day loop below then priced EVERY re-derived day of this holding
            // with the current quote. A window spanning a holiday (nothing
            // between 09-30 and 10-08) came out flat at today's prices and
            // the period's real move landed on 10-05.
            //
            // Tolerated only for a holding that has barely existed yet (see
            // [_newHoldingGraceDays]): there is no earlier baseline to
            // distort and every day it has is priced at its latest price
            // already. Anything older aborts, exactly like a thrown fetch.
            if (buyDay.isBefore(
              todayDate.subtract(const Duration(days: _newHoldingGraceDays)),
            )) {
              failedSymbols.add(symbol);
            }
            return;
          }
          fillers[h.id] = HistoryPriceLookup(history);
        } catch (_) {
          // Record the failure; we abort the whole rebuild below rather than
          // letting the day-by-day loop substitute the current price for the
          // entire history of this holding.
          failedSymbols.add(symbol);
        }
      }());
    }
    await Future.wait(futures);
    // Phase 2: amount-based cash holdings — their principal must see the
    // complete sell-principal map captured in phase 1.
    for (final h in holdings) {
      if (!isSmoothedHolding(h)) continue;
      if (!AssetType.fromStorage(h.assetType).isAmountBased) continue;
      final flows = await _dao.getTransactionsForHolding(h.id);
      smoothValues[h.id] = smoothCalc.amountHistory(
        h,
        flows,
        from: windowStart,
        to: current,
        today: current,
      );
      smoothPrincipals[h.id] = smoothCalc.amountPrincipal(
        h,
        flows,
        from: windowStart,
        to: current,
        soldPrincipalById: soldPrincipalById,
      );
    }
    final coveredHoldings = fillers.length + smoothValues.length;

    // If any market-source fetch failed (e.g. network error), abort without
    // writing a single snapshot. Writing would fall back to the current
    // latest price for every historical date of the failed holding and
    // corrupt the net-worth history. The user can re-run the backfill once
    // the network is back.
    if (failedSymbols.isNotEmpty) {
      return BackfillResult(
        ok: false,
        days: 0,
        holdings: 0,
        historyUnavailable: true,
        message:
            '历史净值获取失败（${failedSymbols.join('、')}），本次未写入任何快照，'
            '请检查网络后重试',
      );
    }

    final firstTimeRebuild =
        await _dao.getSetting(_backfillV3Marker) == null ||
        await _dao.getSetting(_shareReplayMarker) == null ||
        await _dao.getSetting(_smoothShareReplayMarker) == null ||
        await _dao.getSetting(_sinaHistoryEndpointMarker) == null ||
        await _dao.getSetting(_tencentGatewayMarker) == null;
    // A type switch that crossed the amount-based boundary changes the
    // *meaning* of the stored numbers (see holding_type_conversion.dart); the
    // days written under the old semantics must not survive a light run (a
    // light run leaves everything before the last run in place, so the curve
    // would show a permanent step where the type changed). The dialog sets
    // this marker and the next run — even a light one — rebuilds the whole
    // window once, then clears it.
    final forceNext = await _dao.getSetting(historyFullRebuildKey) == '1';
    final needFullRebuild = forceRebuild || forceNext || firstTimeRebuild;
    final existingDates = <String>{};
    // Anchor recorded by the previous run. Null on a full rebuild (every day
    // is re-derived, so there is nothing to anchor against) and on a first
    // run, which is also when the fixed fallback window below applies.
    DateTime? lastRun;
    if (!needFullRebuild) {
      existingDates.addAll((await _dao.getSnapshots()).map((s) => s.date));
      // Re-derive today and everything since the previous run. Today is the
      // day the live path wrote first; the earlier days are the ones it wrote
      // on previous launches and may have frozen mid-session (see the class
      // doc). Every other existing day is left alone on a light run.
      //
      // With no recorded previous run there is nothing to anchor to, so reach
      // back a fixed span rather than defaulting to today alone — otherwise
      // the first launch after upgrading re-derives just one day and leaves a
      // frozen day (the bug being repaired) in place for good.
      lastRun = _parseDay(await _dao.getSetting(_lastRunKey));
      var reopenFrom =
          lastRun ??
          DateTime(
            todayDate.year,
            todayDate.month,
            todayDate.day - _firstRunLookbackDays,
          );
      if (reopenFrom.isAfter(todayDate)) reopenFrom = todayDate;
      for (
        var d = reopenFrom;
        !d.isAfter(todayDate);
        d = d.add(const Duration(days: 1))
      ) {
        existingDates.remove(todayKey(d));
      }
    }

    // Compute the full window day by day, today included.
    var day = DateTime(earliest.year, earliest.month, earliest.day);
    final rows = <SnapshotRow>[];
    while (!day.isAfter(todayDate)) {
      final key = todayKey(day);
      if (existingDates.contains(key)) {
        day = day.add(const Duration(days: 1));
        continue;
      }
      var assets = 0.0;
      var liabilities = 0.0;
      var cost = 0.0;
      var hasPrice = false;
      for (final h in holdings) {
        final buy = h.purchaseDate ?? h.createdAt;
        final buyDay = DateTime(buy.year, buy.month, buy.day);
        // The holding did not exist yet on this day.
        if (day.isBefore(buyDay)) continue;
        final type = AssetType.fromStorage(h.assetType);
        // Convert to CNY: market value at the current rate, cost at the
        // recorded purchase rate (falling back to the current rate).
        if (isSmoothedHolding(h)) {
          final double value;
          if (type.isAmountBased) {
            value = smoothValues[h.id]?[key] ?? h.quantity;
          } else {
            final price = smoothCalc.sharePrice(h, day, windowStart, current);
            // The replayed quantity, so days held before a redemption keep
            // the pre-redemption position (see [_smoothShareReplayMarker]).
            final replayed = replays[h.id]?[key];
            final qty = replayed?.$1 ?? h.quantity;
            value = qty * price;
          }
          if (value > 0) hasPrice = true;
          assets += value * valueRateOf(h, cnyRates);
          // The historical cost is the replayed principal (not the current
          // costPrice), so days before a repayment/borrowing keep their
          // pre-transfer invested amount — the value/cost pair then changes
          // together and transfers never leak into the daily return.
          final principal = type.isAmountBased
              ? (smoothPrincipals[h.id]?[key] ??
                    effectiveCostOf(h))
              // Replayed total cost for share-based smoothed holdings too.
              : (replays[h.id]?[key]?.$2 ?? h.quantity * h.costPrice);
          cost += principal * costRateOf(h, cnyRates);
          continue;
        }
        final filler = fillers[h.id];
        final hist = filler?.priceOnOrBefore(key);
        // TODAY prices with the LIVE latest price, unconditionally (mirroring
        // [dayHoldingsBreakdown]): after a refresh the cached quote is newer
        // than the history series and is exactly the figure the portfolio
        // page / live snapshot shows — so the last day of a rebuild sums to
        // the same numbers. Whether the history series already contains
        // today's close is irrelevant (it may also lag midday).
        //
        // Every other day is priced from the series and NOTHING ELSE: a
        // historical day whose price is unknown must not be filled with the
        // current quote, which belongs to another day — that substitution is
        // what flattened a whole holiday window onto its first day and moved
        // the period's return there. When the series does not reach back far
        // enough, the nearest known historical price (its earliest row)
        // stands in rather than today's.
        final isToday = key == todayKey(todayDate);
        final price = isToday
            ? h.latestPrice
            : (hist ?? filler?.firstPrice ?? h.latestPrice);
        if (price > 0) hasPrice = true;
        // Historical quantity/cost from the flow replay: a sold-out fund
        // still shows its real market value on the days it was held (v8).
        // Absent a replay row (holding created after the window start is
        // guarded by the buy-day check) fall back to the current position.
        final replayed = replays[h.id]?[key];
        final shares = replayed?.$1 ?? h.quantity;
        final value = shares * price * valueRateOf(h, cnyRates);
        if (type == AssetType.liability) {
          liabilities += value;
        } else {
          assets += value;
          // Amount-based assets store the cumulative invested amount in
          // costPrice; share-based ones use the replayed total cost (unit
          // cost moves through buys/sells/dividends/splits).
          cost +=
              (type.isAmountBased
                  ? effectiveCostOf(h)
                  : replayed?.$2 ?? shares * h.costPrice) *
              costRateOf(h, cnyRates);
        }
      }
      if (hasPrice) {
        rows.add(
          SnapshotRow(
            date: key,
            currency: 'CNY',
            totalValue: assets - liabilities,
            totalCost: cost,
            liabilities: liabilities,
            createdAt: current,
          ),
        );
      }
      day = day.add(const Duration(days: 1));
    }

    // Swap atomically so the UI never sees an empty/mid-write state.
    if (rows.isNotEmpty) {
      await _dao.transaction(() async {
        if (needFullRebuild) {
          // Days this pass re-derives must not be tombstoned: the rebuilt row
          // is itself the newer version that wins the merge, whereas a
          // tombstone stamped now (later than the rebuild's start time, which
          // the rows carry) would outrank it and delete it again on the next
          // sync. See [AssetDao.deleteSnapshotsBefore].
          final replaced = <String>{
            for (final r in rows) '${r.date}|${r.currency}',
          };
          await _dao.deleteSnapshotsBefore(
            todayKey(current),
            replacedKeys: replaced,
          );
        }
        await _dao.batchInsertSnapshots(rows);
      });
    }
    // Mark the one-time rebuild done only after a successful swap.
    if (firstTimeRebuild) {
      await _dao.setSetting(
        _backfillV3Marker,
        '${current.millisecondsSinceEpoch}',
      );
      await _dao.setSetting(
        _shareReplayMarker,
        '${current.millisecondsSinceEpoch}',
      );
      await _dao.setSetting(
        _smoothShareReplayMarker,
        '${current.millisecondsSinceEpoch}',
      );
      await _dao.setSetting(
        _sinaHistoryEndpointMarker,
        '${current.millisecondsSinceEpoch}',
      );
      await _dao.setSetting(
        _tencentGatewayMarker,
        '${current.millisecondsSinceEpoch}',
      );
    }
    // Clear the forced-full-rebuild marker only after the swap succeeded,
    // so a run aborted by a network failure retries the full rebuild next
    // launch instead of silently leaving the old-semantics days in place.
    if (forceNext) {
      await _dao.setSetting(historyFullRebuildKey, '0');
    }
    // Remember where the next light run must re-derive from. Written only
    // after the swap succeeded, so an aborted run leaves the previous anchor
    // in place and the same days are retried on the next launch.
    //
    // Skipped when the anchor already holds today. Re-writing it would not
    // change the data, but it is not a no-op for anything watching the
    // settings table: drift emits on every write to it, and this line runs on
    // every light pass — which is exactly how the backfill used to spin its
    // own caller (see [AssetDao.watchSetting]).
    final anchor = todayKey(todayDate);
    if (lastRun == null || todayKey(lastRun) != anchor) {
      await _dao.setSetting(_lastRunKey, anchor);
    }

    return BackfillResult(
      ok: true,
      days: rows.length,
      holdings: coveredHoldings,
      wroteToday: rows.any((r) => r.date == todayKey(todayDate)),
      message: rows.isEmpty ? '历史净值已是最新' : '已回填 ${rows.length} 天历史净值',
    );
  }

  /// Parses a yyyy-MM-dd setting value; null when absent or malformed.
  static DateTime? _parseDay(String? value) {
    if (value == null) return null;
    final parts = value.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Per-holding (value, cost) on [day], in CNY, computed with the EXACT
  /// same pricing/replay rules as [backfill] — the day-detail panel under
  /// the earnings calendar uses this so its per-product sum equals the
  /// calendar cell (they previously drifted via a separate
  /// ProductEarningsService path). Returns one entry per holding owned on
  /// [day]; liabilities carry [DayHoldingValue.liability] == true.
  Future<List<DayHoldingValue>> dayHoldingsBreakdown(DateTime day) async {
    final holdings = await _dao.getHoldings();
    if (holdings.isEmpty) return const [];
    final target = DateTime(day.year, day.month, day.day);
    // A FIXED window start (the earliest holding purchase), identical to
    // [backfill]. Smooth/interpolated holdings price the day by its index
    // within this single window, so querying two consecutive days uses the
    // SAME interpolation and their difference is the day's change. Using the
    // queried day as the window start (as first written) made every smoothed
    // holding price day D at its window's first index — i.e. at the cost
    // price — while today priced at the latest price, so the panel showed the
    // all-time gain instead of the day change (2026-10-02 汇利日盈 +1718.64).
    DateTime? earliest;
    for (final h in holdings) {
      final d = h.purchaseDate ?? h.createdAt;
      if (earliest == null || d.isBefore(earliest)) earliest = d;
    }
    final windowStart = earliest ?? target;
    final current = DateTime.now();

    final currencies = holdings
        .where((h) => h.currency != 'CNY' && !isFxLinked(h))
        .map((h) => h.currency)
        .toSet()
        .toList();
    final market = _market;
    final cnyRates = market == null
        ? const <String, double>{}
        : await market.loadCnyRates(currencies);

    final smoothCalc = const SmoothHistoryCalculator();
    final smoothValues = <int, Map<String, double>>{};
    final smoothPrincipals = <int, Map<String, double>>{};
    final fillers = <int, HistoryPriceLookup>{};
    final replays = <int, Map<String, (double, double)>>{};
    final soldPrincipalById = <int, double>{};
    final futures = <Future<void>>[];

    for (final h in holdings) {
      final type = AssetType.fromStorage(h.assetType);
      final source = MarketSource.fromStorage(h.marketSource);
      if (isSmoothedHolding(h)) {
        if (!type.isAmountBased) {
          final flows = await _dao.getTransactionsForHolding(h.id);
          replays[h.id] = const HoldingReplay().replay(
            h,
            flows,
            from: windowStart,
            to: current,
            capturedSellPrincipal: soldPrincipalById,
          );
        }
        continue;
      }
      final adapter = _sources[source];
      if (adapter == null) continue;
      var rawSymbol = (h.symbol != null && h.symbol!.isNotEmpty)
          ? h.symbol!
          : type.defaultSymbol;
      if (rawSymbol == null) continue;
      if (source == MarketSource.sina) {
        rawSymbol = normalizeSinaSymbol(rawSymbol);
      }
      final symbol = rawSymbol;
      final flows = await _dao.getTransactionsForHolding(h.id);
      replays[h.id] = const HoldingReplay().replay(
        h,
        flows,
        from: windowStart,
        to: current,
        capturedSellPrincipal: soldPrincipalById,
      );
      futures.add(() async {
        try {
          final history = await adapter.fetch(symbol, windowStart, current);
          if (history.isNotEmpty) fillers[h.id] = HistoryPriceLookup(history);
        } catch (_) {
          // Ignore a single source failure; fall back to latest price below.
        }
      }());
    }
    await Future.wait(futures);

    for (final h in holdings) {
      if (!isSmoothedHolding(h)) continue;
      if (!AssetType.fromStorage(h.assetType).isAmountBased) continue;
      final flows = await _dao.getTransactionsForHolding(h.id);
      smoothValues[h.id] = smoothCalc.amountHistory(
        h,
        flows,
        from: windowStart,
        to: current,
        today: current,
      );
      smoothPrincipals[h.id] = smoothCalc.amountPrincipal(
        h,
        flows,
        from: windowStart,
        to: current,
        soldPrincipalById: soldPrincipalById,
      );
    }

    final key = todayKey(target);
    final out = <DayHoldingValue>[];
    for (final h in holdings) {
      final buy = h.purchaseDate ?? h.createdAt;
      final buyDay = DateTime(buy.year, buy.month, buy.day);
      if (target.isBefore(buyDay)) continue;
      final type = AssetType.fromStorage(h.assetType);
      final double value;
      final double cost;
      if (isSmoothedHolding(h)) {
        final double v;
        if (type.isAmountBased) {
          v = smoothValues[h.id]?[key] ?? h.quantity;
        } else {
          final price = smoothCalc.sharePrice(h, target, windowStart, current);
          final replayed = replays[h.id]?[key];
          final qty = replayed?.$1 ?? h.quantity;
          v = qty * price;
        }
        value = v * valueRateOf(h, cnyRates);
        final principal = type.isAmountBased
            ? (smoothPrincipals[h.id]?[key] ??
                  effectiveCostOf(h))
            : (replays[h.id]?[key]?.$2 ?? h.quantity * h.costPrice);
        cost = principal * costRateOf(h, cnyRates);
      } else {
        final filler = fillers[h.id];
        final hist = filler?.priceOnOrBefore(key);
        // TODAY prices with the LIVE latest price, unconditionally — the
        // same rule [backfill] uses, so the day detail sums to the snapshot
        // the rebuild wrote. A historical day is never priced from the
        // current quote; it forward-fills from the series and, when the
        // series does not reach that far back, falls back to its earliest
        // row — the same rule [backfill] applies.
        final price = _isSameDay(target, DateTime.now())
            ? h.latestPrice
            : (hist ?? filler?.firstPrice ?? h.latestPrice);
        final replayed = replays[h.id]?[key];
        final shares = replayed?.$1 ?? h.quantity;
        value = shares * price * valueRateOf(h, cnyRates);
        cost =
            (type.isAmountBased
                ? effectiveCostOf(h)
                : replayed?.$2 ?? shares * h.costPrice) *
            costRateOf(h, cnyRates);
      }
      out.add(
        DayHoldingValue(
          holdingId: h.id,
          name: h.name,
          type: type,
          value: value,
          cost: cost,
          liability: type == AssetType.liability,
        ),
      );
    }
    return out;
  }
}

/// One holding's (market value, cost) on a specific day, in CNY — computed
/// with the EXACT same pricing/replay rules as the net-worth snapshots, so a
/// per-holding breakdown sums to the day's snapshot totals.
class DayHoldingValue {
  const DayHoldingValue({
    required this.holdingId,
    required this.name,
    required this.type,
    required this.value,
    required this.cost,
    required this.liability,
  });

  final int holdingId;
  final String name;
  final AssetType type;
  final double value;
  final double cost;
  final bool liability;
}
