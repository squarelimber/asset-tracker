import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/range_stats.dart';

SnapshotRow _snap(String date, double value) {
  return SnapshotRow(
    date: date,
    currency: 'CNY',
    totalValue: value,
    totalCost: 0,
    createdAt: DateTime(2026, 1, 1),
  );
}

void main() {
  const calc = RangeStatsCalculator();

  test('RangeOption start dates', () {
    final now = DateTime(2026, 8, 8);
    expect(RangeOption.month1.startDate(now), DateTime(2026, 7, 8));
    expect(RangeOption.month3.startDate(now), DateTime(2026, 5, 8));
    expect(RangeOption.year1.startDate(now), DateTime(2025, 8, 8));
    expect(RangeOption.year3.startDate(now), DateTime(2023, 8, 8));
    expect(RangeOption.all.startDate(now), isNull);
  });

  test('range stats computed from first/last points', () {
    final stats = calc.compute([
      _snap('2025-08-08', 100000),
      _snap('2025-09-08', 110000),
      _snap('2026-08-08', 120000),
    ]);
    expect(stats, isNotNull);
    expect(stats!.startValue, 100000);
    expect(stats.endValue, 120000);
    expect(stats.change, 20000);
    expect(stats.changePct, closeTo(0.2, 1e-9));
    expect(stats.days, 365);
    expect(stats.annualized, closeTo(0.2, 1e-9));
  });

  test('annualized over half a year roughly doubles the simple return', () {
    final stats = calc.compute([
      _snap('2026-02-08', 100000),
      _snap('2026-08-08', 110000),
    ]);
    expect(stats!.days, 181);
    expect(stats.annualized!, closeTo(0.21, 0.02));
  });

  test('null when fewer than two points', () {
    expect(calc.compute([]), isNull);
    expect(calc.compute([_snap('2026-08-08', 100)]), isNull);
  });

  test('filter keeps only the requested window', () {
    final all = [
      _snap('2026-01-01', 100),
      _snap('2026-02-01', 110),
      _snap('2026-03-01', 120),
      _snap('2026-04-01', 130),
    ];
    final filtered = calc.filter(all, from: '2026-02-01', to: '2026-03-01');
    expect(filtered.map((s) => s.date).toList(), ['2026-02-01', '2026-03-01']);
    expect(calc.filter(all), all);
  });

  test('annualized is null on total loss', () {
    final stats = calc.compute([
      _snap('2026-01-01', 100000),
      _snap('2026-08-08', 0),
    ]);
    expect(stats!.changePct, -1);
    expect(stats.annualized, isNull);
  });
}
