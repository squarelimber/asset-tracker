import '../core/enums.dart';
import '../core/formats.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/smooth_history.dart';
import '../services/market/history_lookup.dart';
import '../services/market/history_source.dart';
import '../services/market/tencent_history_source.dart';

/// One holding's contribution on a given day.
class HoldingDayDetail {
  const HoldingDayDetail({
    required this.holding,
    required this.price,
    required this.marketValue,
    required this.cost,
    required this.ratio,
    this.cnyRate = 1,
    this.prevPrice,
    this.dayChange,
    this.dayChangePct,
  });

  final HoldingRow holding;

  /// Unit price on that day (or latest for manual assets), in the
  /// holding's own currency.
  final double price;

  /// Market value in the holding's own currency.
  final double marketValue;

  /// Cost basis in the holding's own currency (current cost semantics:
  /// invested for amount-based assets, qty x unit cost otherwise).
  final double cost;

  /// Share of total assets (0..1); liabilities are excluded from the base.
  final double ratio;

  /// CNY per unit of the holding's currency (1 for CNY).
  final double cnyRate;

  /// The previous trading day's price (null when there is no baseline,
  /// e.g. the purchase day).
  final double? prevPrice;

  /// Day change in the holding's own currency: (price - prevPrice) x qty.
  /// Null without a baseline (purchase day, amount-based, liabilities).
  final double? dayChange;

  /// Day change as a fraction of the previous price (0.01 = +1%).
  final double? dayChangePct;

  double get profit => marketValue - cost;

  /// Market value converted to CNY.
  double get marketValueCny => marketValue * cnyRate;

  /// Cost converted to CNY.
  double get costCny => cost * cnyRate;

  double get profitCny => marketValueCny - costCny;
}

/// Full detail of one day: total value plus per-holding breakdown.
/// [totalValue] is in CNY (converted); per-item values stay in the
/// holding's own currency with [cnyRate] available for conversion.
class DayDetail {
  const DayDetail({
    required this.date,
    required this.totalValue,
    required this.items,
  });

  final String date;
  final double totalValue;
  final List<HoldingDayDetail> items;
}

/// Computes per-holding breakdown for a given day by fetching historical
/// prices on demand (reusing the same sources as the backfill service).
/// Results are cached in memory so repeat taps are instant.
class HoldingDetailService {
  HoldingDetailService(this._dao, {Map<MarketSource, HistoryDataSource>? sources})
      : _sources = sources ??
            {
              MarketSource.eastmoney: EastmoneyHistorySource(),
              // Tencent qfq (adjusted) klines keep unit splits/ex-rights
              // continuous, matching the backfill service.
              MarketSource.sina: TencentHistorySource(),
              MarketSource.sge: AuGoldHistorySource(),
            };

  final AssetDao _dao;
  final Map<MarketSource, HistoryDataSource> _sources;

  final Map<String, DayDetail> _cache = {};

  /// Computes the day's per-holding breakdown.
  /// [cnyRates] maps ISO currency code -> CNY per unit (default 1); the
  /// total value is converted to CNY while per-item values keep their own
  /// currency (with [HoldingDayDetail.cnyRate] for display conversion).
  Future<DayDetail?> compute(
    DateTime day, {
    Map<String, double> cnyRates = const {},
  }) async {
    final key = todayKey(day);
    final cached = _cache[key];
    if (cached != null) return cached;

    double rateOf(String currency) {
      final rate = cnyRates[currency.toUpperCase()];
      return (rate == null || rate <= 0) ? 1 : rate;
    }

    final holdings = await _dao.getHoldings();
    if (holdings.isEmpty) return null;

    // Fetch history from the earliest purchase date to the target day so
    // weekends/holidays resolve via forward fill (same as the backfill).
    DateTime? earliest;
    for (final h in holdings) {
      final d = h.purchaseDate ?? h.createdAt;
      if (earliest == null || d.isBefore(earliest)) earliest = d;
    }

    // Fetch historical prices in parallel.
    final smoothCalc = const SmoothHistoryCalculator();
    final smoothValues = <int, Map<String, double>>{};
    final lookups = <int, HistoryPriceLookup>{};
    final futures = <Future<void>>[];
    for (final h in holdings) {
      if (isSmoothedHolding(h)) {
        if (AssetType.fromStorage(h.assetType).isAmountBased) {
          final flows = await _dao.getTransactionsForHolding(h.id);
          smoothValues[h.id] = smoothCalc.amountHistory(
            h,
            flows,
            from: earliest ?? day,
            to: day,
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
          final history = await adapter.fetch(symbol, earliest ?? day, day);
          if (history.isNotEmpty) lookups[h.id] = HistoryPriceLookup(history);
        } catch (_) {
          // Ignore a single source failure; fall back to latest price.
        }
      }());
    }
    await Future.wait(futures);

    var assetsCny = 0.0;
    var liabilitiesCny = 0.0;
    final rawItems = <HoldingDayDetail>[];
    for (final h in holdings) {
      final type = AssetType.fromStorage(h.assetType);
      final buy = h.purchaseDate ?? h.createdAt;
      final buyDay = DateTime(buy.year, buy.month, buy.day);
      // Not owned yet on this day.
      if (day.isBefore(buyDay)) continue;

      final lookup = lookups[h.id];
      double price;
      double value;
      if (isSmoothedHolding(h)) {
        if (type.isAmountBased) {
          price = 1;
          value = smoothValues[h.id]?[key] ?? h.quantity;
        } else {
          price = smoothCalc.sharePrice(h, day, earliest ?? day, day);
          value = h.quantity * price;
        }
      } else {
        final hist = lookup?.priceOnOrBefore(key);
        final last = lookup?.lastDate;
        // Prefer the live latest price for TODAY when the history endpoint
        // lags behind (e.g. a NAV published after the history data
        // updated), so the day detail matches the snapshot numbers.
        // Historical days keep the forward-fill semantics.
        if (hist == null ||
            (last != null &&
                last.compareTo(key) < 0 &&
                _isSameDay(day, DateTime.now()))) {
          price = h.latestPrice;
        } else {
          price = hist;
        }
        value = h.quantity * price;
      }
      final rate = rateOf(h.currency);
      // Cost converts at the recorded purchase rate when available.
      final cost = (type.isAmountBased
              ? (h.costPrice > 0 ? h.costPrice : h.quantity)
              : h.quantity * h.costPrice) *
          costRateOf(h, cnyRates);

      // Day change: price vs the previous trading day (only meaningful for
      // market-linked holdings; amount-based assets and liabilities have no
      // price series).
      double? prevPrice;
      double? dayChange;
      double? dayChangePct;
      if (!type.isAmountBased && type != AssetType.liability) {
        final prevDay = day.subtract(const Duration(days: 1));
        final prevKey = todayKey(prevDay);
        final double prev;
        if (isSmoothedHolding(h)) {
          prev = smoothCalc.sharePrice(h, prevDay, earliest ?? day, day);
        } else {
          prev = lookup?.priceOnOrBefore(prevKey) ?? -1;
        }
        if (prev > 0 && price > 0) {
          prevPrice = prev;
          dayChange = (price - prev) * h.quantity;
          dayChangePct = (price - prev) / prev;
        }
      } else if (isSmoothedHolding(h) && type.isAmountBased) {
        // Smooth amount-based accrual: today's interpolated value minus
        // yesterday's, so the daily accrual shows up in the detail sheet.
        final prevKey = todayKey(day.subtract(const Duration(days: 1)));
        final prevValue = smoothValues[h.id]?[prevKey];
        if (prevValue != null && prevValue > 0 && value > 0) {
          dayChange = value - prevValue;
          dayChangePct = (value - prevValue) / prevValue;
          prevPrice = 1;
        }
      }

      if (type == AssetType.liability) {
        liabilitiesCny += value * rate;
      } else {
        assetsCny += value * rate;
      }
      rawItems.add(HoldingDayDetail(
        holding: h,
        price: price,
        marketValue: value,
        cost: cost,
        cnyRate: rate,
        ratio: 0,
        prevPrice: prevPrice,
        dayChange: dayChange,
        dayChangePct: dayChangePct,
      ));
    }

    final items = [
      for (final it in rawItems)
        if (AssetType.fromStorage(it.holding.assetType) != AssetType.liability)
          HoldingDayDetail(
            holding: it.holding,
            price: it.price,
            marketValue: it.marketValue,
            cost: it.cost,
            cnyRate: it.cnyRate,
            ratio: assetsCny == 0 ? 0 : it.marketValueCny / assetsCny,
            prevPrice: it.prevPrice,
            dayChange: it.dayChange,
            dayChangePct: it.dayChangePct,
          )
        else
          it,
    ]..sort((a, b) {
        // Sort by day change percentage descending; entries without a
        // baseline (purchase day, amount-based, liabilities) go last.
        final ap = a.dayChangePct;
        final bp = b.dayChangePct;
        if (ap == null && bp == null) return 0;
        if (ap == null) return 1;
        if (bp == null) return -1;
        return bp.compareTo(ap);
      });
    if (items.isEmpty) return null;

    final detail = DayDetail(
      date: key,
      totalValue: assetsCny - liabilitiesCny,
      items: items,
    );
    _cache[key] = detail;
    return detail;
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
