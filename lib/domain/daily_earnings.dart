import '../core/formats.dart';
import '../data/database.dart';

/// One day's earnings in the cost-basis view.
class DailyEarning {
  const DailyEarning({
    required this.date,
    required double profit,
    required this.totalValue,
    required this.totalCost,
    required this.liabilities,
    this.fromDate,
    this.openingAssets,
  }) : intervalProfit = profit;

  /// Snapshot date (yyyy-MM-dd).
  final String date;

  /// Daily asset return = today's (assets − cost + realized gain) minus
  /// yesterday's, where
  /// `assets = totalValue + liabilities` (net worth with the debt added
  /// back). Liability changes — credit-card spending, borrowing, repayment —
  /// move the debt line without touching the portfolio, so they never count
  /// as gains or losses; principal in/out moves the cost along with the
  /// balance and nets out the same way.
  final double intervalProfit;
  final String? fromDate;
  final double? openingAssets;
  bool get spansMultipleDays => fromDate != null && fromDate != date;
  double? get profit => spansMultipleDays ? null : intervalProfit;

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
    this.hasUnallocatedProfit = false,
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
  final bool hasUnallocatedProfit;
}

/// Yearly aggregate over [MonthlyEarnings].
class YearlyEarnings {
  const YearlyEarnings({
    required this.year,
    required this.total,
    required this.rate,
    required this.months,
    this.hasUnallocatedProfit = false,
  });

  final int year;

  /// Sum of monthly profits over the year.
  final double total;

  /// Yearly return = total / asset value at year start (null when the year
  /// has no data or the base is non-positive).
  final double? rate;

  /// Months of the year that have data.
  final List<MonthlyEarnings> months;
  final bool hasUnallocatedProfit;
}

/// Today's earning in the snapshot view: the last snapshot's asset profit
/// minus the previous one — the same number the earnings calendar shows on
/// today's cell. Null when snapshots are unavailable.
///
/// The last row must actually be today's ([now], wall clock by default).
/// Without that check a day whose snapshot has not been written yet (or a
/// device that has not synced today) reported the difference between two
/// *earlier* days as "today's earning" — the number then belonged to
/// yesterday while sitting next to a live-computed total, so the two
/// figures on the same card described different moments in time.
({double profit, double? pct})? todayEarningOf(
  List<SnapshotRow> snapshots, {
  DateTime? now,
}) {
  if (snapshots.isEmpty) return null;
  if (snapshots.last.date != todayKey(now ?? DateTime.now())) return null;
  final today = snapshots.last;
  if (snapshots.length < 2) return (profit: 0.0, pct: null);
  final yesterday = snapshots[snapshots.length - 2];
  if (nextSnapshotDate(yesterday.date) != today.date) return null;
  final profitToday = snapshotAssetProfit(today);
  final profitYesterday = snapshotAssetProfit(yesterday);
  final profit = profitToday - profitYesterday;
  final base = snapshotAssets(yesterday);
  final pct = base <= 0 ? null : profit / base;
  return (profit: profit, pct: pct);
}

double snapshotAssets(SnapshotRow row) => row.totalValue + row.liabilities;

double snapshotAssetProfit(SnapshotRow row) =>
    snapshotAssets(row) - row.totalCost + (row.realizedProfit ?? 0);

DateTime? snapshotCalendarDate(String day) {
  final parsed = DateTime.tryParse(day);
  if (parsed == null || todayKey(parsed) != day) return null;
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

String? nextSnapshotDate(String day) {
  final date = snapshotCalendarDate(day);
  if (date == null) return null;
  // Calendar arithmetic avoids DST changing the length of a day.
  return todayKey(DateTime.utc(date.year, date.month, date.day + 1));
}

/// Computes per-day earnings from daily snapshots.
///
/// Snapshots must be ordered by date ascending. The first available day
/// has no previous baseline, so its profit is 0.
class DailyEarningsCalculator {
  const DailyEarningsCalculator();

  List<DailyEarning> compute(List<SnapshotRow> snapshots) {
    final result = <DailyEarning>[];
    SnapshotRow? previous;
    for (final s in snapshots) {
      if (snapshotCalendarDate(s.date) == null) continue;
      result.add(
        DailyEarning(
          date: s.date,
          profit: previous == null
              ? 0
              : snapshotAssetProfit(s) - snapshotAssetProfit(previous),
          totalValue: s.totalValue,
          totalCost: s.totalCost,
          liabilities: s.liabilities,
          fromDate: previous == null ? null : nextSnapshotDate(previous.date),
          openingAssets: previous == null ? null : snapshotAssets(previous),
        ),
      );
      previous = s;
    }
    return result;
  }

  /// Aggregates the earnings of [year]-[month] from precomputed daily
  /// earnings (any order).
  MonthlyEarnings monthOf(List<DailyEarning> earnings, int year, int month) {
    final period = _periodOf(
      earnings,
      DateTime.utc(year, month),
      DateTime.utc(year, month + 1),
    );
    return MonthlyEarnings(
      year: year,
      month: month,
      total: period.total,
      rate: period.rate,
      days: period.days,
      hasUnallocatedProfit: period.hasUnallocatedProfit,
    );
  }

  /// Aggregates all months of [year] into a yearly summary.
  YearlyEarnings yearOf(List<DailyEarning> earnings, int year) {
    final months = <MonthlyEarnings>[];
    for (var m = 1; m <= 12; m++) {
      final agg = monthOf(earnings, year, m);
      if (agg.days > 0 || agg.hasUnallocatedProfit) months.add(agg);
    }
    // A gap can prevent precise monthly attribution while the annual
    // difference remains known if both ends of the gap are inside the year.
    final period = _periodOf(
      earnings,
      DateTime.utc(year),
      DateTime.utc(year + 1),
    );
    return YearlyEarnings(
      year: year,
      total: period.total,
      rate: period.rate,
      months: months,
      hasUnallocatedProfit: period.hasUnallocatedProfit,
    );
  }

  ({double total, double? rate, int days, bool hasUnallocatedProfit}) _periodOf(
    List<DailyEarning> earnings,
    DateTime start,
    DateTime end,
  ) {
    final first = todayKey(start);
    final until = todayKey(end);
    var total = 0.0;
    var days = 0;
    var hasUnallocatedProfit = false;
    DailyEarning? opening;
    for (final earning in earnings) {
      final from = earning.fromDate ?? earning.date;
      if (from.compareTo(until) >= 0 || earning.date.compareTo(first) < 0) {
        continue;
      }
      final endsInPeriod = earning.date.compareTo(until) < 0;
      if (endsInPeriod) days++;
      if (from.compareTo(first) < 0 || !endsInPeriod) {
        hasUnallocatedProfit = true;
        continue;
      }
      total += earning.intervalProfit;
      if (opening == null || earning.date.compareTo(opening.date) < 0) {
        opening = earning;
      }
    }
    final base =
        opening?.openingAssets ??
        (opening == null ? 0 : opening.totalValue + opening.liabilities);
    return (
      total: total,
      rate: hasUnallocatedProfit || base <= 0 ? null : total / base,
      days: days,
      hasUnallocatedProfit: hasUnallocatedProfit,
    );
  }
}
