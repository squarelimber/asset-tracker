import 'dart:math';

import '../data/database.dart';

/// Return-rate series math (capital-gains view).
///
/// The daily return rate is `(market value - invested cost) / invested cost`.
/// Money flowing in raises both value and cost, so the rate is immune to
/// deposits/transfers — exactly what an index comparison needs.
class RateSeriesCalculator {
  const RateSeriesCalculator();

  /// Daily return rate as a fraction (-1..). Cost 0 -> 0.
  static double dailyRate(double value, double cost) {
    if (cost <= 0) return 0;
    return (value - cost) / cost;
  }

  /// Return rates (%) aligned with the given snapshots.
  List<double> ratesOf(List<SnapshotRow> snapshots) {
    return [
      for (final s in snapshots) dailyRate(s.totalValue, s.totalCost) * 100,
    ];
  }

  /// Range return in percentage points: end rate - start rate.
  double? rangeRatePct(List<SnapshotRow> snapshots) {
    if (snapshots.length < 2) return null;
    final start = dailyRate(snapshots.first.totalValue, snapshots.first.totalCost);
    final end = dailyRate(snapshots.last.totalValue, snapshots.last.totalCost);
    return (end - start) * 100;
  }

  /// Annualized return over the range from the rate delta (fraction).
  double? annualizedFromRange(List<SnapshotRow> snapshots) {
    final delta = rangeRatePct(snapshots);
    if (delta == null) return null;
    final first = DateTime.tryParse(snapshots.first.date);
    final last = DateTime.tryParse(snapshots.last.date);
    if (first == null || last == null) return null;
    final days = last.difference(first).inDays;
    if (days <= 0) return null;
    final deltaFraction = delta / 100;
    if (deltaFraction <= -1) return null;
    return pow(1 + deltaFraction, 365.0 / days) - 1;
  }
}
