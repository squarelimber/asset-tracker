import 'package:flutter/foundation.dart' show kIsWeb;

import '../core/enums.dart';
import '../core/formats.dart';
import '../core/history_sync.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
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
  }) : _sources = sources ??
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

  /// Backfills snapshots for dates before today.
  ///
  /// By default only missing days are filled. With [forceRebuild], the whole
  /// window (including already-snapshot days) is recomputed and overwritten,
  /// which merges newly added / edited / removed holdings into the history.
  Future<BackfillResult> backfill({DateTime? now, bool forceRebuild = false}) async {
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
      return const BackfillResult(ok: false, days: 0, holdings: 0, message: '暂无持仓');
    }

    // Earliest purchase date across holdings defines the window start.
    DateTime? earliest;
    for (final h in holdings) {
      final d = h.purchaseDate ?? h.createdAt;
      if (earliest == null || d.isBefore(earliest)) earliest = d;
    }
    if (earliest == null) return const BackfillResult(ok: false, days: 0, holdings: 0);
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
        message: '缺少汇率（${missingRates.join('、')}），本次未写入任何快照，'
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
    final futures = <Future<void>>[];
    // Symbols whose history fetch threw. A network failure must NOT be
    // silently swallowed: the day-by-day loop would otherwise fall back to
    // the *current* latest price for every historical date of that holding,
    // corrupting the whole net-worth history (seen 2026-09-04: a bad network
    // on fetch day produced a truncated/failed series and the snapshots for
    // 2020-08..2026-09 came out wrong). We collect failures and abort below
    // instead of writing bad rows.
    final failedSymbols = <String>[];
    for (final h in holdings) {
      if (isSmoothedHolding(h)) {
        if (AssetType.fromStorage(h.assetType).isAmountBased) {
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
          );
        }
        continue;
      }
      final source = MarketSource.fromStorage(h.marketSource);
      final adapter = _sources[source];
      if (adapter == null) continue;
      final type = AssetType.fromStorage(h.assetType);
      var rawSymbol = (h.symbol != null && h.symbol!.isNotEmpty)
          ? h.symbol!
          : type.defaultSymbol;
      if (rawSymbol == null) continue;
      if (source == MarketSource.sina) {
        rawSymbol = normalizeSinaSymbol(rawSymbol);
      }
      final symbol = rawSymbol;
      futures.add(() async {
        try {
          final history = await adapter.fetch(symbol, windowStart, current);
          if (history.isNotEmpty) fillers[h.id] = HistoryPriceLookup(history);
        } catch (_) {
          // Record the failure; we abort the whole rebuild below rather than
          // letting the day-by-day loop substitute the current price for the
          // entire history of this holding.
          failedSymbols.add(symbol);
        }
      }());
    }
    await Future.wait(futures);
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

    final firstTimeRebuild = await _dao.getSetting(_backfillV3Marker) == null;
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
      var reopenFrom = lastRun ??
          DateTime(
            todayDate.year,
            todayDate.month,
            todayDate.day - _firstRunLookbackDays,
          );
      if (reopenFrom.isAfter(todayDate)) reopenFrom = todayDate;
      for (var d = reopenFrom;
          !d.isAfter(todayDate);
          d = d.add(const Duration(days: 1))) {
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
            value = h.quantity * price;
          }
          if (value > 0) hasPrice = true;
          assets += value * valueRateOf(h, cnyRates);
          // The historical cost is the replayed principal (not the current
          // costPrice), so days before a repayment/borrowing keep their
          // pre-transfer invested amount — the value/cost pair then changes
          // together and transfers never leak into the daily return.
          final principal = type.isAmountBased
              ? (smoothPrincipals[h.id]?[key] ??
                  (h.costPrice > 0 ? h.costPrice : h.quantity))
              : h.quantity * h.costPrice;
          cost += principal * costRateOf(h, cnyRates);
          continue;
        }
        final filler = fillers[h.id];
        final price = filler?.priceOnOrBefore(key) ?? h.latestPrice;
        if (price > 0) hasPrice = true;
        final value = h.quantity * price * valueRateOf(h, cnyRates);
        if (type == AssetType.liability) {
          liabilities += value;
        } else {
          assets += value;
          // Amount-based assets store the cumulative invested amount in
          // costPrice; unit-based assets store the per-unit cost.
          cost += (type.isAmountBased
                  ? (h.costPrice > 0 ? h.costPrice : h.quantity)
                  : h.quantity * h.costPrice) *
              costRateOf(h, cnyRates);
        }
      }
      if (hasPrice) {
        rows.add(SnapshotRow(
          date: key,
          currency: 'CNY',
          totalValue: assets - liabilities,
          totalCost: cost,
          liabilities: liabilities,
          createdAt: current,
        ));
      }
      day = day.add(const Duration(days: 1));
    }

    // Swap atomically so the UI never sees an empty/mid-write state.
    if (rows.isNotEmpty) {
      await _dao.transaction(() async {
        if (needFullRebuild) {
          await _dao.deleteSnapshotsBefore(todayKey(current));
        }
        await _dao.batchInsertSnapshots(rows);
      });
    }
    // Mark the one-time rebuild done only after a successful swap.
    if (firstTimeRebuild) {
      await _dao.setSetting(_backfillV3Marker, '${current.millisecondsSinceEpoch}');
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
}
