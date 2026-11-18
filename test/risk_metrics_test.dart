import 'dart:math' as math;

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/risk_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final first = DateTime(2025, 1, 1);
  List<SnapshotRow> series(int returnCount) {
    var value = 1000.0;
    return [
      for (var i = 0; i <= returnCount; i++)
        () {
          if (i > 0) value *= 1 + (i.isEven ? 0.002 : -0.001);
          final day = first.add(Duration(days: i));
          return SnapshotRow(
            date:
                '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
            currency: 'CNY',
            totalValue: value,
            totalCost: 1000,
            liabilities: 0,
            createdAt: day,
          );
        }(),
    ];
  }

  TransactionRow flow(DateTime day) => TransactionRow(
    id: 1,
    accountId: 1,
    type: 'buy',
    amount: 1,
    currency: 'CNY',
    occurredAt: day,
    costMoved: false,
    internalMove: false,
    updatedAt: day,
  );

  test(
    'uses sample volatility, calendar-day annualization and the chosen risk-free rate',
    () {
      final values = series(30);
      final result = estimateRiskMetrics(
        values,
        [],
        annualRiskFreeRate: .01,
        now: DateTime(2026),
      );
      final mean = .0005;
      final sd = math.sqrt(30 * math.pow(.0015, 2) / 29);
      final riskFreeDay = math.pow(1.01, 1 / 365) - 1;
      expect(result.sampleCount, 30);
      expect(result.startDate, '2025-01-01');
      expect(result.endDate, '2025-01-31');
      expect(result.annualizedVolatility, closeTo(sd * math.sqrt(365), 1e-10));
      expect(
        result.sharpe,
        closeTo((mean - riskFreeDay) / sd * math.sqrt(365), 1e-9),
      );
      expect(result.unavailableReason, isNull);
    },
  );

  test('flows and missing days break the latest usable segment', () {
    final values = series(75);
    final withFlow = estimateRiskMetrics(
      values,
      [flow(first.add(const Duration(days: 50)))],
      annualRiskFreeRate: 0,
      now: DateTime(2026),
    );
    expect(withFlow.sampleCount, 25);
    expect(withFlow.startDate, '2025-02-20');
    expect(withFlow.sharpe, isNull);
    final missing = [...values]..removeAt(50);
    final withGap = estimateRiskMetrics(
      missing,
      [],
      annualRiskFreeRate: 0,
      now: DateTime(2026),
    );
    expect(withGap.sampleCount, 24);
    expect(withGap.sharpe, isNull);
  });

  test('excludes today and caps samples at 365 days', () {
    final values = series(400);
    final result = estimateRiskMetrics(
      values,
      [],
      annualRiskFreeRate: .01,
      now: first.add(const Duration(days: 400)),
    );
    expect(result.sampleCount, 365);
    expect(result.endDate, values[399].date);
    expect(result.startDate, values[34].date);
  });

  test(
    'unexplained cost changes break the segment, rounding noise does not',
    () {
      final values = series(80);
      final changed = [
        for (var i = 0; i < values.length; i++)
          i < 40 ? values[i] : values[i].copyWith(totalCost: 1100),
      ];
      final result = estimateRiskMetrics(
        changed,
        [],
        annualRiskFreeRate: 0,
        now: DateTime(2026),
      );
      expect(result.sampleCount, 40);
      expect(result.startDate, values[40].date);
      final roundingNoise = [...values]
        ..[40] = values[40].copyWith(totalCost: 1000 + 1e-7);
      final rounded = estimateRiskMetrics(
        roundingNoise,
        [],
        annualRiskFreeRate: 0,
        now: DateTime(2026),
      );
      expect(rounded.sampleCount, 80);
    },
  );

  test('snapshot predating a transaction cannot start the next return', () {
    final values = series(40);
    final day = first.add(const Duration(days: 10));
    final transaction = flow(
      day,
    ).copyWith(updatedAt: day.add(const Duration(hours: 1)));
    final result = estimateRiskMetrics(
      values,
      [transaction],
      annualRiskFreeRate: 0,
      now: DateTime(2026),
    );
    expect(result.sampleCount, 29);
    expect(result.startDate, values[11].date);
    expect(result.sharpe, isNull);
  });

  test(
    'backfilled transaction invalidates later snapshots until regenerated',
    () {
      final values = series(80);
      final transaction = flow(
        first.add(const Duration(days: 10)),
      ).copyWith(updatedAt: first.add(const Duration(days: 30, hours: 12)));
      final result = estimateRiskMetrics(
        values,
        [transaction],
        annualRiskFreeRate: 0,
        now: DateTime(2026),
      );
      expect(result.sampleCount, 49);
      expect(result.startDate, values[31].date);
      expect(result.endDate, values[80].date);
      expect(result.sharpe, isNotNull);
    },
  );

  test(
    'zero volatility, nonpositive assets and invalid risk-free rate are unavailable',
    () {
      final values = series(35);
      final constant = [
        for (final value in values) value.copyWith(totalValue: 1000),
      ];
      final zero = estimateRiskMetrics(
        constant,
        [],
        annualRiskFreeRate: 0,
        now: DateTime(2026),
      );
      expect(zero.sharpe, isNull);
      expect(zero.annualizedVolatility, 0);
      final invalid = [...values]..[20] = values[20].copyWith(totalValue: 0);
      expect(
        estimateRiskMetrics(
          invalid,
          [],
          annualRiskFreeRate: 0,
          now: DateTime(2026),
        ).sampleCount,
        14,
      );
      expect(
        estimateRiskMetrics(
          values,
          [],
          annualRiskFreeRate: -1,
          now: DateTime(2026),
        ).unavailableReason,
        '无风险年利率无效',
      );
    },
  );
}
