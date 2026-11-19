import '../core/enums.dart';
import '../core/formats.dart';
import '../data/database.dart';
import 'transaction_identity.dart';

/// One month's earnings for one product (all accounts merged by name).
class ProductMonthEarning {
  const ProductMonthEarning({
    required this.year,
    required this.month,
    required this.profit,
    this.rate,
    required this.days,
    this.dailyProfits = const [],
    this.closed,
  });

  final int year;
  final int month;

  /// Sum of daily Δ(value - cost) over the month (CNY).
  final double profit;

  /// Monthly return = profit / product value at month start (null when the
  /// month has no data or the base is non-positive).
  final double? rate;

  /// Number of days with data in the month.
  final int days;

  /// Profit for each day with a position or a closing valuation.
  final List<double> dailyProfits;

  /// The product's final closing valuation falls inside this month.
  final bool? closed;
}

/// Earnings of one product (all accounts merged by name) over a window.
class ProductEarnings {
  const ProductEarnings({
    required this.name,
    required this.type,
    required this.closed,
    required this.daily,
    this.holdingIds = const [],
    this.dailyProfitAdjustments = const {},
  });

  /// Product name - the merge key across accounts.
  final String name;

  /// Positions whose valuations were merged into this product.
  final List<int> holdingIds;

  /// Asset type of the first holding (for the icon).
  final AssetType type;

  /// Fully sold out as of today.
  final bool closed;

  /// Merged per-day (date, value, cost) series, CNY-converted, ascending.
  final List<({String date, double value, double cost})> daily;

  /// Adjustments to the change in unrealized profit attributable to this
  /// product, e.g. gains carried between holdings by an internal transfer.
  /// These do not alter the recorded values or cost bases.
  final Map<String, double> dailyProfitAdjustments;
}

/// One day's value/cost for one holding, CNY-converted.
class HoldingDay {
  const HoldingDay({
    required this.date,
    required this.value,
    required this.cost,
    this.profitAdjustment = 0,
  });

  final String date;
  final double value;
  final double cost;
  final double profitAdjustment;
}

/// Per-day value/cost series for one holding (ascending dates).
class HoldingSeries {
  const HoldingSeries({
    required this.holdingId,
    required this.name,
    required this.type,
    required this.closed,
    required this.days,
  });

  final int holdingId;
  final String name;
  final AssetType type;

  /// Fully sold out as of today (quantity == 0).
  final bool closed;

  final List<HoldingDay> days;
}

/// Monthly earnings per product, in the same cost-basis convention as the
/// earnings calendar (DailyEarningsCalculator): daily profit =
/// Δ(value - cost), so buys/sells (principal flows) never show up as gains.
/// Sold-out products keep their full history because quantity and cost are
/// replayed from the flows.
class ProductEarningsCalculator {
  const ProductEarningsCalculator();

  /// Merges holdings by name (same product bought in several accounts) and
  /// returns one [ProductEarnings] per product.
  List<ProductEarnings> compute(List<HoldingSeries> series) {
    final groups = <String, List<HoldingSeries>>{};
    for (final s in series) {
      (groups[s.name] ??= <HoldingSeries>[]).add(s);
    }
    final products = <ProductEarnings>[];
    for (final entry in groups.entries) {
      final members = entry.value;
      final byDate = <String, (double value, double cost)>{};
      final adjustmentsByDate = <String, double>{};
      for (final m in members) {
        for (final d in m.days) {
          if (d.profitAdjustment != 0) {
            adjustmentsByDate[d.date] =
                (adjustmentsByDate[d.date] ?? 0) + d.profitAdjustment;
          }
          final cur = byDate[d.date];
          byDate[d.date] = cur == null
              ? (d.value, d.cost)
              : (cur.$1 + d.value, cur.$2 + d.cost);
        }
      }
      final dates = byDate.keys.toList()..sort();
      products.add(ProductEarnings(
        name: entry.key,
        type: members.first.type,
        closed: members.every((m) => m.closed),
        holdingIds: List.unmodifiable(
          members.map((holding) => holding.holdingId),
        ),
        dailyProfitAdjustments: adjustmentsByDate,
        daily: [
          for (final date in dates)
            (date: date, value: byDate[date]!.$1, cost: byDate[date]!.$2),
        ],
      ));
    }
    return products;
  }

  /// Monthly earnings for [year]-[month] from a product's merged daily
  /// series. The first available day has no previous baseline, so its
  /// profit is 0 (same convention as the earnings calendar).
  ProductMonthEarning monthOf(ProductEarnings p, int year, int month) {
    final prefix = '$year-${month.toString().padLeft(2, '0')}-';
    final dailyProfits = <double>[];
    double? base;
    int? lastIndex;
    for (var i = 0; i < p.daily.length; i++) {
      final cur = p.daily[i];
      if (!cur.date.startsWith(prefix) || !_hasObservation(p, i)) continue;
      final prev = i > 0 ? p.daily[i - 1] : null;
      final openingValue = prev?.value ?? 0;
      base ??= openingValue > 0 ? openingValue : cur.value;
      lastIndex = i;
      dailyProfits.add(
        prev == null
            ? 0.0
            : (cur.value - cur.cost) -
                  (prev.value - prev.cost) +
                  (p.dailyProfitAdjustments[cur.date] ?? 0),
      );
    }
    final profit = dailyProfits.fold(0.0, (sum, profit) => sum + profit);
    var closedInMonth = false;
    if (p.closed && lastIndex != null) {
      final lastPosition = p.daily.lastIndexWhere(_hasPosition);
      final closeIndex = lastPosition == p.daily.length - 1
          ? lastPosition
          : lastPosition + 1;
      closedInMonth = lastIndex == closeIndex;
    }
    return ProductMonthEarning(
      year: year,
      month: month,
      profit: profit,
      rate: base == null || base <= 0 ? null : profit / base,
      days: dailyProfits.length,
      dailyProfits: dailyProfits,
      closed: closedInMonth ? true : null,
    );
  }

  static bool _hasPosition(({String date, double value, double cost}) day) =>
      day.value != 0 || day.cost != 0;

  // Snapshots can pad the series with zero balances. A transition from a
  // real position to zero still belongs to the day it was recorded.
  static bool _hasObservation(ProductEarnings p, int i) =>
      _hasPosition(p.daily[i]) ||
      (i > 0 && _hasPosition(p.daily[i - 1])) ||
      (p.dailyProfitAdjustments[p.daily[i].date] ?? 0) != 0;

  /// All months of [year] that have data, in ascending order.
  List<ProductMonthEarning> yearOf(ProductEarnings p, int year) {
    final months = <ProductMonthEarning>[];
    for (var m = 1; m <= 12; m++) {
      final agg = monthOf(p, year, m);
      if (agg.days > 0) months.add(agg);
    }
    return months;
  }

  /// Yearly profit = sum of the months' daily profits.
  double yearlyProfit(List<ProductMonthEarning> months) =>
      months.fold(0.0, (sum, m) => sum + m.profit);

  /// Yearly return = yearly profit / product value on the year's first day.
  double? yearlyRate(List<ProductMonthEarning> months, ProductEarnings p, int year) {
    if (months.isEmpty) return null;
    final firstPrefix =
        '$year-${months.first.month.toString().padLeft(2, '0')}-';
    for (var i = 0; i < p.daily.length; i++) {
      final d = p.daily[i];
      if (d.date.startsWith(firstPrefix) && _hasObservation(p, i)) {
        final openingValue = i > 0 ? p.daily[i - 1].value : 0;
        final base = openingValue > 0 ? openingValue : d.value;
        return base <= 0 ? null : yearlyProfit(months) / base;
      }
    }
    return null;
  }
}

/// Replays a holding's quantity and total cost day by day from its
/// transactions, so sold-out (quantity = 0) holdings still expose their
/// historical position.
///
/// Flow semantics (mirroring TransactionService):
/// - buy:      quantity +q, total cost +amount (funded buys move only the
///   principal the cash leg actually travelled — costMovedAmount — so the
///   cash account's unrealized gain is not re-booked as new cost)
/// - sell:     quantity -q, total cost -q x unit cost (unit cost unchanged)
/// - dividend: total cost -amount (capital repayment)
/// - split:    quantity x ratio, total cost unchanged (ratio in amount)
///
/// The replay runs forwards on (quantity, unit cost). The initial unit cost
/// before the first flow is reconstructed from the current state by
/// reversing the flows. For a full sale, the recorded sold principal or
/// retained unit cost can restore the cost of the position before the sale.
typedef _ReplayEvent = (
  DateTime day,
  TransactionType type,
  double qty,
  double amount,
  double costBasis, // amount that enters/leaves the cost basis for this leg
  int txnId,
  double? soldPrincipal,
);

class HoldingReplay {
  const HoldingReplay();

  /// Daily (quantity, totalCost) for [h] over [from]..[to] (both
  /// inclusive). [flows] may be in any order; only buy/sell/dividend/split
  /// rows of this holding are used.
  ///
  /// [capturedSellPrincipal], when given, receives each sell's principal
  /// (quantity x unit cost at the moment of sale) keyed by transaction id —
  /// the number a receiving cash account must credit to its own principal so
  /// the sell's unrealized gain stays on the cash side (see
  /// SmoothHistoryCalculator's sell-proceeds leg). Mirrors
  /// TransactionService._applySell's soldPrincipal.
  Map<String, (double quantity, double cost)> replay(
    HoldingRow h,
    List<TransactionRow> flows, {
    required DateTime from,
    required DateTime to,
    Map<int, double>? capturedSellPrincipal,
  }) {
    final fromDay = DateTime(from.year, from.month, from.day);
    final toDay = DateTime(to.year, to.month, to.day);

    final orderedFlows = flows.where((t) => t.holdingId == h.id).toList()
      ..sort((a, b) {
        final time = a.occurredAt.compareTo(b.occurredAt);
        return time == 0 ? compareTransactionEntryOrder(a, b) : time;
      });
    final events = <_ReplayEvent>[];
    for (final t in orderedFlows) {
      final type = TransactionType.fromStorage(t.type);
      if (type != TransactionType.buy &&
          type != TransactionType.sell &&
          type != TransactionType.dividend &&
          type != TransactionType.split) {
        continue;
      }
      // A cash-funded or redemption-funded buy receives the principal
      // recorded on the flow, which can differ from the amount paid.
      final fundedBuy = type == TransactionType.buy &&
          (t.cashSourceId != null || t.internalMove);
      final costBasis = fundedBuy ? (t.costMovedAmount ?? t.amount) : t.amount;
      final keepsPrincipal = type == TransactionType.sell &&
          (t.cashTargetId != null || t.internalMove);
      events.add((
        DateTime(t.occurredAt.year, t.occurredAt.month, t.occurredAt.day),
        type,
        t.quantity ?? 0,
        t.amount,
        costBasis,
        t.id,
        isExternalSale(t) ? t.externalSellPrincipal :
            (keepsPrincipal ? t.costMovedAmount : null),
      ));
    }

    // Reconstruct the initial (quantity, unit cost) before the earliest
    // flow by reversing the flows from the current state.
    var q = h.quantity;
    var u = q > 0 ? h.costPrice : 0.0;
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      switch (e.$2) {
        case TransactionType.buy:
          final qBefore = q - e.$3;
          if (qBefore > 0) {
            u = (u * q - e.$5) / qBefore;
          }
          q = qBefore;
        case TransactionType.sell:
          if (q <= 0 && e.$3 > 0) {
            final soldPrincipal = e.$7;
            if (soldPrincipal != null) {
              u = soldPrincipal / e.$3;
            } else if (i == events.length - 1 && h.costPrice > 0) {
              u = h.costPrice;
            } else {
              u = e.$4 / e.$3;
            }
          }
          q += e.$3;
        case TransactionType.dividend:
          if (q > 0) u += e.$4 / q;
        case TransactionType.split:
          if (e.$4 > 0) {
            q /= e.$4;
            u *= e.$4;
          }
        default:
          break;
      }
    }
    if (q < 0) q = 0;
    if (u < 0) u = 0;

    // Forward replay over the window.
    final result = <String, (double, double)>{};
    var day = fromDay;
    var i = 0;
    var curQ = q;
    var curU = u;
    void captureIfSell(_ReplayEvent e, double unitNow) {
      if (capturedSellPrincipal == null || e.$2 != TransactionType.sell) return;
      if (e.$3 <= 0) return;
      // Principal of the sold shares = qty x unit cost at sale time, so the
      // receiving cash account credits exactly this (not the full proceeds).
      capturedSellPrincipal[e.$6] = e.$7 ?? e.$3 * unitNow;
    }

    while (!day.isAfter(toDay)) {
      while (i < events.length && !events[i].$1.isAfter(day)) {
        captureIfSell(events[i], curU);
        (curQ, curU) = _apply(events[i], curQ, curU);
        i++;
      }
      // Once the last flow is applied, the ledger confirms the position is
      // empty. Floating-point roundoff can otherwise leave tiny shares.
      result[todayKey(day)] = i == events.length && h.quantity == 0
          ? (0.0, 0.0)
          : (curQ, curQ * curU);
      day = DateTime(day.year, day.month, day.day + 1);
    }
    return result;
  }

  (double, double) _apply(_ReplayEvent e, double q, double u) {
    switch (e.$2) {
      case TransactionType.buy:
        if (e.$3 <= 0) return (q, u);
        final newQ = q + e.$3;
        final newU = newQ > 0 ? (u * q + e.$5) / newQ : 0.0;
        return (newQ, newU);
      case TransactionType.sell:
        final newQ = (q - e.$3).clamp(0.0, double.infinity);
        return (newQ, newQ > 0 ? u : 0.0);
      case TransactionType.dividend:
        if (q <= 0) return (q, u);
        return (q, (u - e.$4 / q).clamp(0.0, double.infinity));
      case TransactionType.split:
        if (e.$4 <= 0) return (q, u);
        return (q * e.$4, u / e.$4);
      default:
        return (q, u);
    }
  }
}
