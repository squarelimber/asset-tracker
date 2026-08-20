import '../core/enums.dart';
import '../core/formats.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/product_monthly_earnings.dart';
import '../domain/smooth_history.dart';
import 'market/history_lookup.dart';
import 'market/history_source.dart';
import 'market/market_service.dart';
import 'market/tencent_history_source.dart';

/// Computes per-product monthly earnings for the product earnings calendar.
///
/// Unlike the portfolio snapshot backfill (which prices every historical day
/// with the *current* quantity and therefore drops sold-out products), this
/// service replays each holding's quantity and cost from its transaction
/// flows, so sold-out products keep their full history and the realized
/// gain/loss of the final sell lands in the sell month.
///
/// Conventions (same cost-basis view as the earnings calendar):
/// - daily profit = Δ(value - cost), so buys/sells are principal flows
/// - on a sell day the position is marked at the recorded sell price, so the
///   realized gain shows up as that day's profit instead of a value collapse
class ProductEarningsService {
  ProductEarningsService(
    this._dao, {
    Map<MarketSource, HistoryDataSource>? sources,
    MarketService? market,
  }) : _sources = sources ??
            {
              MarketSource.eastmoney: EastmoneyHistorySource(),
              MarketSource.sina: TencentHistorySource(),
              MarketSource.sge: AuGoldHistorySource(),
            } {
    _market = market;
  }

  final AssetDao _dao;
  final Map<MarketSource, HistoryDataSource> _sources;
  MarketService? _market;

  /// Per-product earnings over [from]..[to] (both inclusive). Products are
  /// merged by name across accounts and sorted by yearly profit descending.
  Future<List<ProductEarnings>> compute({
    required DateTime from,
    DateTime? to,
  }) async {
    final current = to ?? DateTime.now();
    final holdings = await _dao.getHoldings();
    if (holdings.isEmpty) return const [];

    final currencies = holdings
        .map((h) => h.currency)
        .where((c) => c != 'CNY')
        .toSet()
        .toList();
    final market = _market;
    final cnyRates = market == null
        ? const <String, double>{}
        : await market.loadCnyRates(currencies);

    final smoothCalc = const SmoothHistoryCalculator();
    final replay = const HoldingReplay();
    final fillers = <int, HistoryPriceLookup>{};
    final smoothValues = <int, Map<String, double>>{};
    final smoothPrincipals = <int, Map<String, double>>{};
    final replays = <int, Map<String, (double, double)>>{};
    final sellMarks = <int, Map<String, double>>{};
    final futures = <Future<void>>[];

    for (final h in holdings) {
      final type = AssetType.fromStorage(h.assetType);
      if (type == AssetType.liability) continue;
      if (isSmoothedHolding(h)) {
        if (type.isAmountBased) {
          final flows = await _dao.getTransactionsForHolding(h.id);
          smoothValues[h.id] =
              smoothCalc.amountHistory(h, flows, from: from, to: current);
          smoothPrincipals[h.id] =
              smoothCalc.amountPrincipal(h, flows, from: from, to: current);
        }
        continue;
      }
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
      futures.add(() async {
        try {
          final history = await adapter.fetch(symbol, from, current);
          if (history.isNotEmpty) fillers[h.id] = HistoryPriceLookup(history);
        } catch (_) {
          // A single source failure must not abort the whole computation.
        }
      }());
      final flows = await _dao.getTransactionsForHolding(h.id);
      replays[h.id] = replay.replay(h, flows, from: from, to: current);
      sellMarks[h.id] = _sellMarks(flows);
    }
    await Future.wait(futures);

    final calc = const ProductEarningsCalculator();
    final seriesList = <HoldingSeries>[];
    for (final h in holdings) {
      final type = AssetType.fromStorage(h.assetType);
      if (type == AssetType.liability) continue;
      final valueRate = valueRateOf(h, cnyRates);
      final costRate = costRateOf(h, cnyRates);
      final closed = h.quantity <= 0;
      final days = <HoldingDay>[];

      if (isSmoothedHolding(h)) {
        if (type.isAmountBased) {
          final values = smoothValues[h.id] ?? const <String, double>{};
          final principals = smoothPrincipals[h.id] ?? const <String, double>{};
          final dates = values.keys.toList()..sort();
          for (final key in dates) {
            days.add(HoldingDay(
              date: key,
              value: values[key]! * valueRate,
              cost: (principals[key] ?? h.quantity) * costRate,
            ));
          }
        } else {
          for (var day = DateTime(from.year, from.month, from.day);
              !day.isAfter(current);
              day = day.add(const Duration(days: 1))) {
            final price = smoothCalc.sharePrice(h, day, from, current);
            days.add(HoldingDay(
              date: todayKey(day),
              value: h.quantity * price * valueRate,
              cost: h.quantity * h.costPrice * costRate,
            ));
          }
        }
      } else {
        final filler = fillers[h.id];
        if (filler == null) continue;
        final replayMap = replays[h.id] ?? const <String, (double, double)>{};
        final marks = sellMarks[h.id] ?? const <String, double>{};
        final keys = replayMap.keys.toList()..sort();
        for (var i = 0; i < keys.length; i++) {
          final key = keys[i];
          final rc = replayMap[key]!;
          final mark = marks[key];
          if (mark != null) {
            // Sell day: the replay already applied the sell (quantity 0),
            // so mark the pre-sell position at the recorded sell price —
            // the realized gain then shows up as this day's profit.
            final pre = i > 0 ? replayMap[keys[i - 1]]! : rc;
            days.add(HoldingDay(
              date: key,
              value: pre.$1 * mark * valueRate,
              cost: pre.$2 * costRate,
            ));
            continue;
          }
          if (rc.$1 <= 0) continue;
          final price = filler.priceOnOrBefore(key);
          if (price == null || price <= 0) continue;
          days.add(HoldingDay(
            date: key,
            value: rc.$1 * price * valueRate,
            cost: rc.$2 * costRate,
          ));
        }
      }
      if (days.isEmpty) continue;
      seriesList.add(HoldingSeries(
        holdingId: h.id,
        name: h.name,
        type: type,
        closed: closed,
        days: days,
      ));
    }

    final products = calc.compute(seriesList);
    products.sort((a, b) {
      final pa = calc.yearlyProfit(calc.yearOf(a, current.year));
      final pb = calc.yearlyProfit(calc.yearOf(b, current.year));
      return pb.compareTo(pa);
    });
    return products;
  }

  /// Sell days -> per-unit sale price (amount / quantity), used to mark the
  /// position at the sell price on the sell day.
  static Map<String, double> _sellMarks(List<TransactionRow> flows) {
    final marks = <String, double>{};
    for (final t in flows) {
      if (TransactionType.fromStorage(t.type) != TransactionType.sell) continue;
      final q = t.quantity;
      if (q == null || q <= 0) continue;
      marks[todayKey(t.occurredAt)] = t.amount / q;
    }
    return marks;
  }
}
