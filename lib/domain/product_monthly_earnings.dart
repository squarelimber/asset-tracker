import '../core/enums.dart';
import '../core/formats.dart';
import '../data/database.dart';

/// One month's earnings for one product (all accounts merged by name).
class ProductMonthEarning {
  const ProductMonthEarning({
    required this.year,
    required this.month,
    required this.profit,
    this.rate,
    required this.days,
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

  /// The product's last data day falls inside this month (it was fully
  /// sold out during the month).
  final bool? closed;
}

/// Earnings of one product (all accounts merged by name) over a window.
class ProductEarnings {
  const ProductEarnings({
    required this.name,
    required this.type,
    required this.closed,
    required this.daily,
  });

  /// Product name - the merge key across accounts.
  final String name;

  /// Asset type of the first holding (for the icon).
  final AssetType type;

  /// Fully sold out as of today.
  final bool closed;

  /// Merged per-day (date, value, cost) series, CNY-converted, ascending.
  final List<({String date, double value, double cost})> daily;
}

/// One day's value/cost for one holding, CNY-converted.
class HoldingDay {
  const HoldingDay({required this.date, required this.value, required this.cost});

  final String date;
  final double value;
  final double cost;
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
      for (final m in members) {
        for (final d in m.days) {
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
    final prefix = '$year-${month.toString().padLeft(2, '0')}';
    final idxs = <int>[];
    for (var i = 0; i < p.daily.length; i++) {
      if (p.daily[i].date.startsWith(prefix)) idxs.add(i);
    }
    if (idxs.isEmpty) {
      return ProductMonthEarning(year: year, month: month, profit: 0, days: 0);
    }
    var profit = 0.0;
    for (var k = 0; k < idxs.length; k++) {
      final i = idxs[k];
      final cur = p.daily[i];
      final prev = i > 0 ? p.daily[i - 1] : null;
      if (prev == null) continue;
      profit += (cur.value - cur.cost) - (prev.value - prev.cost);
    }
    final base = p.daily[idxs.first].value;
    final lastIdx = idxs.last;
    final lastDate = p.daily[lastIdx].date;
    final closedInMonth =
        p.closed && lastIdx == p.daily.length - 1 && lastDate.startsWith(prefix);
    return ProductMonthEarning(
      year: year,
      month: month,
      profit: profit,
      rate: base <= 0 ? null : profit / base,
      days: idxs.length,
      closed: closedInMonth ? true : null,
    );
  }

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
    for (final d in p.daily) {
      if (d.date.startsWith(firstPrefix)) {
        return d.value <= 0 ? null : yearlyProfit(months) / d.value;
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
/// - buy:      quantity +q, total cost +amount
/// - sell:     quantity -q, total cost -q x unit cost (unit cost unchanged)
/// - dividend: total cost -amount (capital repayment)
/// - split:    quantity x ratio, total cost unchanged (ratio in amount)
///
/// The replay runs forwards on (quantity, unit cost). The initial unit cost
/// before the first flow is reconstructed from the current state by
/// reversing the flows; when the holding is sold out the unit cost of the
/// final emptying sell is unknown (0/0) and the per-unit sale price is used
/// as a fallback.
typedef _ReplayEvent = (DateTime day, TransactionType type, double qty, double amount);

class HoldingReplay {
  const HoldingReplay();

  /// Daily (quantity, totalCost) for [h] over [from]..[to] (both
  /// inclusive). [flows] may be in any order; only buy/sell/dividend/split
  /// rows of this holding are used.
  Map<String, (double quantity, double cost)> replay(
    HoldingRow h,
    List<TransactionRow> flows, {
    required DateTime from,
    required DateTime to,
  }) {
    final fromDay = DateTime(from.year, from.month, from.day);
    final toDay = DateTime(to.year, to.month, to.day);

    final events = <_ReplayEvent>[];
    for (final t in flows) {
      final type = TransactionType.fromStorage(t.type);
      if (type != TransactionType.buy &&
          type != TransactionType.sell &&
          type != TransactionType.dividend &&
          type != TransactionType.split) {
        continue;
      }
      events.add((
        DateTime(t.occurredAt.year, t.occurredAt.month, t.occurredAt.day),
        type,
        t.quantity ?? 0,
        t.amount,
      ));
    }
    events.sort((a, b) => a.$1.compareTo(b.$1)); // oldest first

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
            u = (u * q - e.$4) / qBefore;
          }
          q = qBefore;
        case TransactionType.sell:
          if (q <= 0 && e.$3 > 0) {
            u = e.$4 / e.$3; // per-unit sale price fallback
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
    while (day.isBefore(toDay)) {
      while (i < events.length && !events[i].$1.isAfter(day)) {
        (curQ, curU) = _apply(events[i], curQ, curU);
        i++;
      }
      result[todayKey(day)] = (curQ, curQ * curU);
      day = day.add(const Duration(days: 1));
    }
    while (i < events.length) {
      (curQ, curU) = _apply(events[i], curQ, curU);
      i++;
    }
    result[todayKey(toDay)] = (curQ, curQ * curU);
    return result;
  }

  (double, double) _apply(_ReplayEvent e, double q, double u) {
    switch (e.$2) {
      case TransactionType.buy:
        if (e.$3 <= 0) return (q, u);
        final newQ = q + e.$3;
        final newU = newQ > 0 ? (u * q + e.$4) / newQ : 0.0;
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
