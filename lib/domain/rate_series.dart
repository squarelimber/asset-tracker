import 'dart:math';

import '../data/database.dart';
import 'daily_earnings.dart';

/// Snapshot-based portfolio performance for comparison with market indices.
class RateSeriesCalculator {
  const RateSeriesCalculator();

  /// Point-in-time gain relative to invested cost.
  static double dailyRate(double value, double cost) {
    if (cost <= 0) return 0;
    return (value - cost) / cost;
  }

  /// Chain each interval's gain divided by its opening assets. A pure
  /// principal flow changes value and cost equally, so its return is zero
  /// even when the opening portfolio already has gains. With snapshot-only
  /// data this treats capital changes as occurring at the interval end.
  List<double> ratesOf(List<SnapshotRow> snapshots) {
    if (snapshots.isEmpty) return const [];
    var growth = 1.0;
    final rates = <double>[0];
    for (var i = 1; i < snapshots.length; i++) {
      final previous = snapshots[i - 1];
      final current = snapshots[i];
      final base = snapshotAssets(previous);
      if (base.isFinite && base > 0) {
        final gain =
            snapshotAssetProfit(current) - snapshotAssetProfit(previous);
        final factor = 1 + gain / base;
        if (factor.isFinite) growth *= max(0, factor);
      }
      rates.add((growth - 1) * 100);
    }
    return rates;
  }

  /// Compounded return in percent over the selected snapshot range.
  double? rangeRatePct(List<SnapshotRow> snapshots) {
    if (snapshots.length < 2) return null;
    return ratesOf(snapshots).last;
  }

  /// Annualized return over the range from the rate delta (fraction).
  double? annualizedFromRange(List<SnapshotRow> snapshots) {
    return annualizedRangeRate(snapshots, rangeRatePct(snapshots));
  }

  double? annualizedRangeRate(List<SnapshotRow> snapshots, double? delta) {
    if (delta == null) return null;
    final first = snapshotCalendarDate(snapshots.first.date);
    final last = snapshotCalendarDate(snapshots.last.date);
    if (first == null || last == null) return null;
    final days = last.difference(first).inDays;
    if (days <= 0) return null;
    final deltaFraction = delta / 100;
    if (deltaFraction <= -1) return null;
    final annualized = pow(1 + deltaFraction, 365.0 / days) - 1;
    return annualized.isFinite ? annualized.toDouble() : null;
  }
}
