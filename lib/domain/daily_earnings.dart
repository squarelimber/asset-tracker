import '../data/database.dart';

/// One day's earnings in the cost-basis view.
class DailyEarning {
  const DailyEarning({
    required this.date,
    required this.profit,
    required this.totalValue,
    required this.totalCost,
    required this.liabilities,
  });

  /// Snapshot date (yyyy-MM-dd).
  final String date;

  /// Daily asset return = (net worth - cost) today minus yesterday. The
  /// snapshot's totalValue already excludes liabilities, and historical
  /// snapshots replay the cost alongside the balance, so principal
  /// repayments / borrowing are cash flows, not gains.
  final double profit;

  final double totalValue;
  final double totalCost;
  final double liabilities;
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

  /// Monthly return = total / asset value at month start (null when the
  /// month has no data or the base is non-positive).
  final double? rate;

  /// Number of days with snapshot data in the month.
  final int days;
}

/// Yearly aggregate over [MonthlyEarnings].
class YearlyEarnings {
  const YearlyEarnings({
    required this.year,
    required this.total,
    required this.rate,
    required this.months,
  });

  final int year;

  /// Sum of monthly profits over the year.
  final double total;

  /// Yearly return = total / asset value at year start (null when the year
  /// has no data or the base is non-positive).
  final double? rate;

  /// Months of the year that have data.
  final List<MonthlyEarnings> months;
}

/// Today's earning in the snapshot view: the last snapshot's asset profit
/// minus the previous one — the same number the earnings calendar shows on
/// today's cell. Null when snapshots are unavailable.
({double profit, double? pct})? todayEarningOf(List<SnapshotRow> snapshots) {
  if (snapshots.isEmpty) return null;
  final today = snapshots.last;
  if (snapshots.length < 2) return (profit: 0.0, pct: null);
  final yesterday = snapshots[snapshots.length - 2];
  final profitToday = _assetProfit(today);
  final profitYesterday = _assetProfit(yesterday);
  final profit = profitToday - profitYesterday;
  final base = yesterday.totalValue;
  final pct = base <= 0 ? null : profit / base;
  return (profit: profit, pct: pct);
}

double _assetProfit(SnapshotRow s) => s.totalValue - s.totalCost;

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
      final currentProfit = _assetProfit(s);
      final prevProfit = i == 0
          ? currentProfit
          : _assetProfit(snapshots[i - 1]);
      result.add(DailyEarning(
        date: s.date,
        profit: currentProfit - prevProfit,
        totalValue: s.totalValue,
        totalCost: s.totalCost,
        liabilities: s.liabilities,
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

  /// Aggregates all months of [year] into a yearly summary.
  YearlyEarnings yearOf(List<DailyEarning> earnings, int year) {
    final months = <MonthlyEarnings>[];
    for (var m = 1; m <= 12; m++) {
      final agg = monthOf(earnings, year, m);
      if (agg.days > 0) months.add(agg);
    }
    if (months.isEmpty) {
      return YearlyEarnings(year: year, total: 0, rate: null, months: const []);
    }
    final total = months.fold(0.0, (sum, m) => sum + m.total);
    // Base = the year's first month's starting net worth.
    final firstPrefix =
        '$year-${months.first.month.toString().padLeft(2, '0')}-';
    final firstDays = earnings
        .where((e) => e.date.startsWith(firstPrefix))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final startBase = firstDays.isEmpty ? 0.0 : firstDays.first.totalValue;
    return YearlyEarnings(
      year: year,
      total: total,
      rate: startBase <= 0 ? null : total / startBase,
      months: months,
    );
  }
}
