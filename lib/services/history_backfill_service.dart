import 'package:flutter/foundation.dart' show kIsWeb;

import '../core/enums.dart';
import '../core/formats.dart';
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
  });

  final bool ok;
  final int days;
  final int holdings;
  final String? message;
}

/// Backfills historical daily net-worth snapshots from each holding's
/// purchase date onward, so the net worth chart shows the full holding
/// period even for assets bought long before the app was first used.
///
/// Data sources:
/// - Mutual funds: Eastmoney NAV history
/// - Stocks / ETFs / LOFs: Sina daily K-line
/// - Gold accumulation: Shanghai gold futures (AU0) history
/// Manual-NAV assets (bank wealth etc.) are carried at their latest price
/// across the backfill window (they only change when the user updates them).
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
              MarketSource.sge: AuGoldHistorySource(),
            } {
    _market = market;
  }

  final AssetDao _dao;
  final Map<MarketSource, HistoryDataSource> _sources;
  MarketService? _market;

  /// Marker for the weekend forward-fill fix + purchase-date filtering:
  /// triggers one atomic recompute of historical snapshots.
  static const _backfillV3Marker = 'backfill_v4_cost_fix';

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
        .map((h) => h.currency)
        .where((c) => c != 'CNY')
        .toSet()
        .toList();
    final market = _market;
    final cnyRates = market == null
        ? const <String, double>{}
        : await market.loadCnyRates(currencies);

    // Fetch history per holding (in parallel). Holdings without a market
    // source (bank wealth, cash management) get a smooth interpolated
    // history instead of a fetched price series.
    final smoothCalc = const SmoothHistoryCalculator();
    final smoothValues = <int, Map<String, double>>{};
    final fillers = <int, HistoryPriceLookup>{};
    final futures = <Future<void>>[];
    for (final h in holdings) {
      if (isSmoothedHolding(h)) {
        if (AssetType.fromStorage(h.assetType).isAmountBased) {
          final flows = await _dao.getTransactionsForHolding(h.id);
          smoothValues[h.id] = smoothCalc.amountHistory(
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
          // A single source failure must not abort the whole rebuild.
        }
      }());
    }
    await Future.wait(futures);
    final coveredHoldings = fillers.length + smoothValues.length;

    final firstTimeRebuild = await _dao.getSetting(_backfillV3Marker) == null;
    final needFullRebuild = forceRebuild || firstTimeRebuild;
    final existingDates = needFullRebuild
        ? <String>{}
        : (await _dao.getSnapshots()).map((s) => s.date).toSet();

    // Compute the full window day by day.
    var day = DateTime(earliest.year, earliest.month, earliest.day);
    final rows = <SnapshotRow>[];
    while (day.isBefore(todayDate)) {
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
          cost += (type.isAmountBased
                  ? (h.costPrice > 0 ? h.costPrice : h.quantity)
                  : h.quantity * h.costPrice) *
              costRateOf(h, cnyRates);
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

    return BackfillResult(
      ok: true,
      days: rows.length,
      holdings: coveredHoldings,
      message: rows.isEmpty ? '历史净值已是最新' : '已回填 ${rows.length} 天历史净值',
    );
  }
}
