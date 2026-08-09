import 'dart:math';

import '../data/database.dart';

/// Selectable trend ranges for the net worth chart.
enum RangeOption {
  month1('近1月'),
  month3('近3月'),
  ytd('今年以来'),
  year1('近1年'),
  year3('近3年'),
  all('全部'),
  custom('自定义');

  const RangeOption(this.label);

  final String label;

  /// Computes the inclusive start date for a preset option, or null for all.
  DateTime? startDate(DateTime now) => switch (this) {
        month1 => DateTime(now.year, now.month - 1, now.day),
        month3 => DateTime(now.year, now.month - 3, now.day),
        ytd => DateTime(now.year, 1, 1),
        year1 => DateTime(now.year - 1, now.month, now.day),
        year3 => DateTime(now.year - 3, now.month, now.day),
        all || custom => null,
      };
}

/// Stats for a selected snapshot range.
///
/// The range profit is measured as the change in `market value - cost`
/// between the first and last snapshot. This is unaffected by new money
/// flowing in during the range (adding 1 yuan raises both value and cost),
/// so it reflects actual gains instead of the net worth growth.
class RangeStats {
  const RangeStats({
    required this.startValue,
    required this.endValue,
    required this.startCost,
    required this.endCost,
    required this.days,
  });

  final double startValue;
  final double endValue;
  final double startCost;
  final double endCost;
  final int days;

  /// Profit at range start (market value - cost).
  double get startProfit => startValue - startCost;

  /// Profit at range end (market value - cost).
  double get endProfit => endValue - endCost;

  /// Gain realized over the range, independent of new investments.
  double get profit => endProfit - startProfit;

  /// Return relative to the capital at range start.
  double get profitPct => startCost == 0 ? 0 : profit / startCost;

  /// Annualized return over the range, null when not computable.
  double? get annualized {
    if (days <= 0 || profitPct <= -1) return null;
    final years = days / 365.0;
    return pow(1 + profitPct, 1 / years) - 1;
  }
}

/// Computes range stats from daily snapshots.
/// Snapshots must already be filtered to the requested window; returns null
/// when fewer than 2 points are available (nothing to compare).
class RangeStatsCalculator {
  const RangeStatsCalculator();

  RangeStats? compute(List<SnapshotRow> snapshots) {
    if (snapshots.length < 2) return null;
    final first = snapshots.first;
    final last = snapshots.last;
    final firstDate = DateTime.tryParse(first.date);
    final lastDate = DateTime.tryParse(last.date);
    final days = (firstDate != null && lastDate != null)
        ? lastDate.difference(firstDate).inDays
        : snapshots.length;
    return RangeStats(
      startValue: first.totalValue,
      endValue: last.totalValue,
      startCost: first.totalCost,
      endCost: last.totalCost,
      days: days,
    );
  }

  /// Filters snapshots to [from]..[to] (dates are yyyy-MM-dd strings).
  List<SnapshotRow> filter(List<SnapshotRow> snapshots, {String? from, String? to}) {
    return snapshots.where((s) {
      if (from != null && s.date.compareTo(from) < 0) return false;
      if (to != null && s.date.compareTo(to) > 0) return false;
      return true;
    }).toList();
  }
}
