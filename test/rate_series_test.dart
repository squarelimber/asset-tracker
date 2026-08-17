import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/rate_series.dart';

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
  const calc = RateSeriesCalculator();

  test('daily rate is (value - cost) / cost', () {
    expect(RateSeriesCalculator.dailyRate(120000, 100000), closeTo(0.2, 1e-9));
    expect(RateSeriesCalculator.dailyRate(90000, 100000), closeTo(-0.1, 1e-9));
    expect(RateSeriesCalculator.dailyRate(5000, 0), 0);
  });

  test('money inflow does not change the rate (capital-gains view)', () {
    // Deposit 50k: value 100k -> 150k, cost 100k -> 150k.
    final before = RateSeriesCalculator.dailyRate(100000, 100000);
    final after = RateSeriesCalculator.dailyRate(150000, 150000);
    expect(after - before, closeTo(0, 1e-9));
  });

  test('ratesOf aligns with snapshots', () {
    final rates = calc.ratesOf([
      _snap('2026-01-01', 110000, 100000),
      _snap('2026-02-01', 120000, 100000),
      _snap('2026-03-01', 90000, 100000),
    ]);
    expect(rates, hasLength(3));
    expect(rates[0], closeTo(10, 1e-9));
    expect(rates[1], closeTo(20, 1e-9));
    expect(rates[2], closeTo(-10, 1e-9));
  });

  test('range rate is end minus start in percentage points', () {
    final delta = calc.rangeRatePct([
      _snap('2026-01-01', 100000, 100000), // 0%
      _snap('2026-08-08', 110000, 100000), // 10%
    ]);
    expect(delta, closeTo(10, 1e-9));
  });

  test('range rate ignores deposits inside the range', () {
    final delta = calc.rangeRatePct([
      _snap('2026-01-01', 100000, 100000), // 0%
      _snap('2026-08-08', 150000, 150000), // deposit of 50k, rate still 0%
    ]);
    expect(delta, closeTo(0, 1e-9));
  });

  test('annualized from range rate delta', () {
    final annualized = calc.annualizedFromRange([
      _snap('2025-08-08', 100000, 100000), // 0%
      _snap('2026-08-08', 110000, 100000), // +10%
    ]);
    expect(annualized, closeTo(0.1, 1e-9));
  });

  test('null for insufficient points', () {
    expect(calc.rangeRatePct([]), isNull);
    expect(calc.rangeRatePct([_snap('2026-01-01', 100, 100)]), isNull);
  });
}

