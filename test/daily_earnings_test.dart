import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/daily_earnings.dart';

SnapshotRow _snap(String date, double value, double cost) {
  return SnapshotRow(
    date: date,
    currency: 'CNY',
    totalValue: value,
    totalCost: cost,
    createdAt: DateTime(2026, 1, 1),
  );
}

void main() {
  const calc = DailyEarningsCalculator();

  test('daily profit is the change of (value - cost)', () {
    final earnings = calc.compute([
      _snap('2026-08-01', 100000, 90000), // profit 10000 (baseline)
      _snap('2026-08-02', 105000, 90000), // +5000
      _snap('2026-08-03', 103000, 90000), // -2000
    ]);
    expect(earnings[0].profit, 0); // first day has no baseline
    expect(earnings[1].profit, closeTo(5000, 1e-9));
    expect(earnings[2].profit, closeTo(-2000, 1e-9));
  });

  test('money inflow does not change the daily profit', () {
    final earnings = calc.compute([
      _snap('2026-08-01', 100000, 100000),
      // Deposit 50k: value and cost both rise.
      _snap('2026-08-02', 150000, 150000),
    ]);
    expect(earnings[1].profit, closeTo(0, 1e-9));
  });

  test('cost-basis dividend shows zero daily profit (value and cost move together)', () {
    final earnings = calc.compute([
      _snap('2026-08-01', 1500, 1500),
      // Ex-dividend: value -500 and cost -500.
      _snap('2026-08-02', 1000, 1000),
    ]);
    expect(earnings[1].profit, closeTo(0, 1e-9));
  });

  test('monthOf aggregates the month with the start-value base', () {
    final earnings = calc.compute([
      _snap('2026-07-31', 100000, 90000),
      _snap('2026-08-01', 100000, 90000),
      _snap('2026-08-02', 105000, 90000),
      _snap('2026-08-03', 103000, 90000),
      _snap('2026-09-01', 110000, 90000),
    ]);
    final month = calc.monthOf(earnings, 2026, 8);
    expect(month.days, 3);
    expect(month.total, closeTo(3000, 1e-9)); // 0 + 5000 - 2000
    expect(month.rate, closeTo(3000 / 100000, 1e-9));
  });

  test('monthOf with no data returns zero with a null rate', () {
    final month = calc.monthOf(const [], 2026, 3);
    expect(month.days, 0);
    expect(month.total, 0);
    expect(month.rate, isNull);
  });
}
