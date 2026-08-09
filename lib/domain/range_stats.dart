import 'dart:math';

import '../data/database.dart';

/// Selectable trend ranges for the net worth chart.
enum RangeOption {
  month1('近1月'),
  month3('近3月'),
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
        year1 => DateTime(now.year - 1, now.month, now.day),
        year3 => DateTime(now.year - 3, now.month, now.day),
        all || custom => null,
      };
}

/// Stats for a selected snapshot range.
class RangeStats {
  const RangeStats({
    required this.startValue,
    required this.endValue,
    required this.days,
  });

  final double startValue;
  final double endValue;
  final int days;

  double get change => endValue - startValue;
  double get changePct => startValue == 0 ? 0 : change / startValue;

  /// Annualized return over the range, null when not computable.
  double? get annualized {
    if (days <= 0 || changePct <= -1) return null;
    final years = days / 365.0;
    return pow(1 + changePct, 1 / years) - 1;
  }
}

/// Computes range stats from daily snapshots.
/// Snapshots must already be filtered to the requested window; returns null
/// when fewer than 2 points are available (nothing to compare).
class RangeStatsCalculator {
  const RangeStatsCalculator();

  RangeStats? compute(List<SnapshotRow> snapshots) {
    if (snapshots.length < 2) return null;
    final start = snapshots.first.totalValue;
    final end = snapshots.last.totalValue;
    final first = DateTime.tryParse(snapshots.first.date);
    final last = DateTime.tryParse(snapshots.last.date);
    final days = (first != null && last != null)
        ? last.difference(first).inDays
        : snapshots.length;
    return RangeStats(startValue: start, endValue: end, days: days);
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
