import '../data/database.dart';

/// One day's earnings in the cost-basis view.
class DailyEarning {
  const DailyEarning({
    required this.date,
    required this.profit,
    required this.totalValue,
    required this.totalCost,
  });

  /// Snapshot date (yyyy-MM-dd).
  final String date;

  /// Daily profit = (value - cost) today minus (value - cost) yesterday.
  /// Immune to money flowing in/out, buys, transfers and cost-basis
  /// dividends (which move value and cost together).
  final double profit;

  final double totalValue;
  final double totalCost;
}

/// Monthly aggregate over [DailyEarning] entries.
class MonthlyEarnings {
  const MonthlyEarnings({
    required this.year,
    required this.month,
    required this.total,
    required this.rate,
    required this.days,
  });

  final int year;
  final int month;

  /// Sum of daily profits over the month.
  final double total;

  /// Monthly return = total / market value at month start (null when the
  /// month has no data or the base is non-positive).
  final double? rate;

  /// Number of days with snapshot data in the month.
  final int days;
}

/// Computes per-day earnings from daily snapshots.
///
/// Snapshots must be ordered by date ascending. The first available day
/// has no previous baseline, so its profit is 0.
class DailyEarningsCalculator {
  const DailyEarningsCalculator();

  List<DailyEarning> compute(List<SnapshotRow> snapshots) {
    final result = <DailyEarning>[];
    for (var i = 0; i < snapshots.length; i++) {
      final s = snapshots[i];
      final currentProfit = s.totalValue - s.totalCost;
      final prevProfit = i == 0
          ? currentProfit
          : snapshots[i - 1].totalValue - snapshots[i - 1].totalCost;
      result.add(DailyEarning(
        date: s.date,
        profit: currentProfit - prevProfit,
        totalValue: s.totalValue,
        totalCost: s.totalCost,
      ));
    }
    return result;
  }

  /// Aggregates the earnings of [year]-[month] from precomputed daily
  /// earnings (any order).
  MonthlyEarnings monthOf(List<DailyEarning> earnings, int year, int month) {
    final prefix = '$year-${month.toString().padLeft(2, '0')}';
    final days = earnings
        .where((e) => e.date.startsWith('$prefix-'))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    if (days.isEmpty) {
      return MonthlyEarnings(year: year, month: month, total: 0, rate: null, days: 0);
    }
    var total = 0.0;
    for (final d in days) {
      total += d.profit;
    }
    final base = days.first.totalValue;
    return MonthlyEarnings(
      year: year,
      month: month,
      total: total,
      rate: base <= 0 ? null : total / base,
      days: days.length,
    );
  }
}
