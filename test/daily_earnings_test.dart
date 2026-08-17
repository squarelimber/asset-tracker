import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/daily_earnings.dart';

SnapshotRow _snap(String date, double value, double cost, {double liabilities = 0}) {
  return SnapshotRow(
    date: date,
    currency: 'CNY',
    totalValue: value,
    totalCost: cost,
    liabilities: liabilities,
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

  test('repayment shows zero daily profit (liability change excluded)', () {
    // Repay 3000: cash falls 3000 (value and cost together), liability
    // falls 3000 (totalValue = assets - liabilities stays flat).
    // Assets = totalValue + liabilities is unchanged on both days, so the
    // earning is 0.
    final earnings = calc.compute([
      _snap('2026-08-01', 97000, 90000, liabilities: 5000),
      _snap('2026-08-02', 97000, 87000, liabilities: 2000),
    ]);
    expect(earnings[1].profit, closeTo(0, 1e-9));
  });

  test('borrowing shows zero daily profit', () {
    final earnings = calc.compute([
      _snap('2026-08-01', 97000, 90000, liabilities: 5000),
      // Borrow 2000: cash +2000 (value and cost together), liability
      // +2000 -> totalValue unchanged, assets unchanged.
      _snap('2026-08-02', 97000, 92000, liabilities: 7000),
    ]);
    expect(earnings[1].profit, closeTo(0, 1e-9));
  });

  test('yearOf aggregates months with the start-of-year base', () {
    final earnings = calc.compute([
      _snap('2025-12-31', 100000, 90000),
      _snap('2026-01-01', 100000, 90000),
      _snap('2026-01-31', 105000, 90000), // Jan +5000
      _snap('2026-02-01', 105000, 90000),
      _snap('2026-02-28', 108000, 90000), // Feb +3000
      _snap('2026-03-01', 108000, 90000), // Mar 0
    ]);
    final year = calc.yearOf(earnings, 2026);
    expect(year.months, hasLength(3)); // Jan, Feb, Mar
    expect(year.total, closeTo(8000, 1e-9));
    expect(year.rate, closeTo(8000 / 100000, 1e-9));
  });

  test('yearOf with no data returns zero with a null rate', () {
    final year = calc.yearOf(const [], 2026);
    expect(year.months, isEmpty);
    expect(year.total, 0);
    expect(year.rate, isNull);
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

  group('todayEarningOf', () {
    test('last snapshot profit minus the previous one', () {
      final earning = todayEarningOf([
        _snap('2026-08-15', 2100000, 2030000), // profit 70000
        _snap('2026-08-16', 2102400, 2030000), // profit 72400
      ]);
      expect(earning, isNotNull);
      expect(earning!.profit, closeTo(2400, 1e-9));
      expect(earning.pct, closeTo(2400 / 2100000, 1e-9));
    });

    test('single snapshot yields zero profit and null pct', () {
      final earning = todayEarningOf([_snap('2026-08-16', 100000, 90000)]);
      expect(earning, isNotNull);
      expect(earning!.profit, 0);
      expect(earning.pct, isNull);
    });

    test('empty list yields null', () {
      expect(todayEarningOf(const []), isNull);
    });

    test('zero yesterday value yields null pct', () {
      final earning = todayEarningOf([
        _snap('2026-08-15', 0, 0),
        _snap('2026-08-16', 100, 0),
      ]);
      expect(earning, isNotNull);
      expect(earning!.profit, closeTo(100, 1e-9));
      expect(earning.pct, isNull);
    });
  });
}

