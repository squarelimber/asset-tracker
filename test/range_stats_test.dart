import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/range_stats.dart';

SnapshotRow _snap(String date, double value, double cost) {
  return SnapshotRow(
    date: date,
    currency: 'CNY',
    totalValue: value,
    totalCost: cost,
    liabilities: 0,
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

  test('range profit is the change of value minus cost', () {
    // Start: value 100k, cost 90k (profit 10k)
    // End:   value 120k, cost 95k (profit 25k)
    final stats = calc.compute([
      _snap('2025-08-08', 100000, 90000),
      _snap('2026-08-08', 120000, 95000),
    ]);
    expect(stats, isNotNull);
    expect(stats!.startProfit, 10000);
    expect(stats.endProfit, 25000);
    expect(stats.profit, 15000);
    expect(stats.profitPct, closeTo(15000 / 90000, 1e-9));
    expect(stats.days, 365);
    expect(stats.annualized, closeTo(stats.profitPct, 1e-9));
  });

  test('new investments during the range do not inflate profit', () {
    // User adds 90k during the year: value 100k -> 200k, cost 100k -> 190k.
    // Actual gains are only 10k, NOT 100k (the old buggy calculation).
    final stats = calc.compute([
      _snap('2025-08-08', 100000, 100000),
      _snap('2026-08-08', 200000, 190000),
    ]);
    expect(stats!.profit, 10000);
    expect(stats.profitPct, closeTo(0.1, 1e-9));
    expect(stats.annualized, closeTo(0.1, 1e-9));
  });

  test('annualized over half a year roughly doubles the simple return', () {
    final stats = calc.compute([
      _snap('2026-02-08', 100000, 100000),
      _snap('2026-08-08', 110000, 100000),
    ]);
    expect(stats!.days, 181);
    expect(stats.annualized!, closeTo(0.21, 0.02));
  });

  test('losses produce negative profit', () {
    final stats = calc.compute([
      _snap('2026-01-01', 100000, 90000),
      _snap('2026-08-08', 95000, 90000),
    ]);
    expect(stats!.profit, -5000);
    expect(stats.profitPct, closeTo(-5000 / 90000, 1e-9));
  });

  test('null when fewer than two points', () {
    expect(calc.compute([]), isNull);
    expect(calc.compute([_snap('2026-08-08', 100, 100)]), isNull);
  });

  test('filter keeps only the requested window', () {
    final all = [
      _snap('2026-01-01', 100, 100),
      _snap('2026-02-01', 110, 100),
      _snap('2026-03-01', 120, 100),
      _snap('2026-04-01', 130, 100),
    ];
    final filtered = calc.filter(all, from: '2026-02-01', to: '2026-03-01');
    expect(filtered.map((s) => s.date).toList(), ['2026-02-01', '2026-03-01']);
    expect(calc.filter(all), all);
  });

  test('annualized is null on total loss', () {
    final stats = calc.compute([
      _snap('2026-01-01', 100000, 100000),
      _snap('2026-08-08', 0, 100000),
    ]);
    expect(stats!.profitPct, -1);
    expect(stats.annualized, isNull);
  });
}

