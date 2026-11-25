import 'dart:math' as math;

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/domain/risk_metrics.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

final _firstDay = DateTime(2025, 1, 1);

DayHoldingValue _value(
  int id,
  double value,
  double cost, {
  AssetType type = AssetType.etf,
  double realized = 0,
  double adjustment = 0,
}) => DayHoldingValue(
  holdingId: id,
  name: '持仓$id',
  type: type,
  value: value,
  cost: cost,
  liability: type == AssetType.liability,
  realizedProfit: realized,
  profitAdjustment: adjustment,
);

SnapshotRow _snapshot(int day, List<DayHoldingValue> values) {
  final assets = values.where((value) => !value.liability);
  final liabilities = values.where((value) => value.liability);
  final date = _firstDay.add(Duration(days: day));
  final debt = liabilities.fold(0.0, (sum, value) => sum + value.value);
  return SnapshotRow(
    date:
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
    currency: 'CNY',
    totalValue: assets.fold(0.0, (sum, value) => sum + value.value) - debt,
    totalCost: assets.fold(0.0, (sum, value) => sum + value.cost),
    liabilities: debt,
    realizedProfit: assets.fold<double>(
      0.0,
      (sum, value) => sum + value.realizedProfit,
    ),
    profitAdjustment: assets.fold<double>(
      0.0,
      (sum, value) => sum + value.profitAdjustment,
    ),
    holdingValues: encodeHoldingValues(values),
    createdAt: DateTime(2026),
  );
}

TransactionRow _transaction(
  int day,
  String type, {
  int? holding = 1,
  int? source,
  int? target,
  double amount = 10,
  double? principal,
  double? externalPrincipal,
  bool internal = false,
  String currency = 'CNY',
  int? id,
}) => TransactionRow(
  id: id ?? day,
  accountId: 1,
  holdingId: holding,
  cashSourceId: source,
  cashTargetId: target,
  type: type,
  amount: amount,
  quantity: 1,
  currency: currency,
  occurredAt: _firstDay.add(Duration(days: day, hours: 12)),
  costMoved: true,
  costMovedAmount: principal,
  externalSellPrincipal: externalPrincipal,
  internalMove: internal,
  updatedAt: _firstDay.add(Duration(days: day, hours: 12)),
);

({List<SnapshotRow> snapshots, List<TransactionRow> transactions}) _cashFlows({
  bool withReturn = false,
}) {
  var cash = 1000.0;
  var gain = 0.0;
  var assets = 2000.0;
  final snapshots = [
    _snapshot(0, [
      _value(1, 1000, 1000),
      _value(2, cash, cash, type: AssetType.cash),
    ]),
  ];
  final transactions = <TransactionRow>[];
  for (var day = 1; day <= 40; day++) {
    if (withReturn) gain += assets * (day.isEven ? .002 : -.001);
    cash += day.isOdd ? 100 : -100;
    assets = 1000 + gain + cash;
    snapshots.add(
      _snapshot(day, [
        _value(1, 1000 + gain, 1000),
        _value(2, cash, cash, type: AssetType.cash),
      ]),
    );
    transactions.add(
      _transaction(
        day,
        day.isOdd ? 'income' : 'expense',
        holding: null,
        target: 2,
        amount: 100,
        principal: 100,
      ),
    );
  }
  return (snapshots: snapshots, transactions: transactions);
}

RiskMetricsEstimate _estimate(
  List<SnapshotRow> snapshots, [
  List<TransactionRow> transactions = const [],
]) => estimateRiskMetrics(
  snapshots,
  transactions,
  annualRiskFreeRate: 0,
  now: DateTime(2026, 4),
);

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

  test(
    'unverifiable legacy flows and missing days break the usable segment',
    () {
      final values = series(75);
      final withFlow = estimateRiskMetrics(
        values,
        [flow(first.add(const Duration(days: 50)))],
        annualRiskFreeRate: 0,
        now: DateTime(2026),
      );
      expect(withFlow.sampleCount, 25);
      expect(withFlow.interruptedDate, '2025-02-20');
      expect(withFlow.interruptionReason, '交易流水缺少可核对的持仓快照');
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
      expect(withGap.interruptedDate, '2025-02-20');
      expect(withGap.interruptionReason, '缺少每日快照');
      expect(withGap.sharpe, isNull);
    },
  );

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

  test(
    'frequent verified internal buys and sells retain all 40 return samples',
    () {
      var stockCost = 400.0;
      var cashCost = 600.0;
      var assets = 1000.0;
      var gain = 0.0;
      final values = [
        _snapshot(0, [
          _value(1, stockCost, stockCost),
          _value(2, cashCost, cashCost, type: AssetType.cash),
        ]),
      ];
      final transactions = <TransactionRow>[];
      for (var day = 1; day <= 40; day++) {
        gain += assets * (day.isEven ? .002 : -.001);
        stockCost += day.isOdd ? 10 : -10;
        cashCost += day.isOdd ? -10 : 10;
        assets = 1000 + gain;
        values.add(
          _snapshot(day, [
            _value(1, stockCost + gain, stockCost),
            _value(2, cashCost, cashCost, type: AssetType.cash),
          ]),
        );
        transactions.add(
          _transaction(
            day,
            day.isOdd ? 'buy' : 'sell',
            source: day.isOdd ? 2 : null,
            target: day.isEven ? 2 : null,
            principal: 10,
            internal: day.isEven,
          ),
        );
      }
      final result = _estimate(values, transactions);
      final deviation = math.sqrt(40 * math.pow(.0015, 2) / 39);
      expect(result.sampleCount, 40);
      expect(result.startDate, values.first.date);
      expect(result.interruptionReason, isNull);
      expect(
        result.annualizedVolatility,
        closeTo(deviation * math.sqrt(365), 1e-10),
      );
      expect(result.sharpe, closeTo(.0005 / deviation * math.sqrt(365), 1e-9));
    },
  );

  test(
    'verified cash deposits and withdrawals produce zero investment return',
    () {
      final inputs = _cashFlows();
      final result = _estimate(inputs.snapshots, inputs.transactions);
      expect(result.sampleCount, 40);
      expect(result.interruptionReason, isNull);
      expect(result.annualizedVolatility, 0);
      expect(result.unavailableReason, '收益波动为零，无法计算夏普比率');
    },
  );

  test('real investment returns on external cash-flow days are retained', () {
    final inputs = _cashFlows(withReturn: true);
    final result = _estimate(inputs.snapshots, inputs.transactions);
    final deviation = math.sqrt(40 * math.pow(.0015, 2) / 39);
    expect(result.sampleCount, 40);
    expect(
      result.annualizedVolatility,
      closeTo(deviation * math.sqrt(365), 1e-10),
    );
    expect(result.sharpe, closeTo(.0005 / deviation * math.sqrt(365), 1e-9));
  });

  test(
    'verified internal transfers and share splits do not interrupt returns',
    () {
      final values = [
        _snapshot(0, [
          _value(1, 400, 400),
          _value(2, 600, 600, type: AssetType.cash),
          _value(3, 0, 0, type: AssetType.cash),
        ]),
        _snapshot(1, [
          _value(1, 402, 400),
          _value(2, 550, 550, type: AssetType.cash),
          _value(3, 50, 50, type: AssetType.cash),
        ]),
        _snapshot(2, [
          _value(1, 401, 400),
          _value(2, 550, 550, type: AssetType.cash),
          _value(3, 50, 50, type: AssetType.cash),
        ]),
      ];
      final result = _estimate(values, [
        _transaction(
          1,
          'transfer_out',
          holding: null,
          source: 2,
          target: 3,
          amount: 50,
          principal: 50,
        ),
        _transaction(2, 'split', amount: 2),
      ]);
      expect(result.sampleCount, 2);
      expect(result.interruptionReason, isNull);
    },
  );

  test(
    'verified external liquidation retains realized return and accepts a zero ending balance',
    () {
      final values = [
        _snapshot(0, [_value(1, 110, 100)]),
        _snapshot(1, [_value(1, 0, 0, realized: 15)]),
      ];
      final result = _estimate(values, [
        _transaction(1, 'sell', amount: 115, externalPrincipal: 100),
      ]);
      expect(result.sampleCount, 1);
      expect(result.interruptionReason, isNull);
    },
  );

  test(
    'unrelated flows cannot hide manual cost edits, even if the edits cancel in total',
    () {
      final values = [
        _snapshot(0, [
          _value(1, 500, 500),
          _value(2, 500, 500),
          _value(3, 0, 0, type: AssetType.cash),
        ]),
        _snapshot(1, [
          _value(1, 500, 510),
          _value(2, 500, 490),
          _value(3, 10, 10, type: AssetType.cash),
        ]),
      ];
      final result = _estimate(values, [
        _transaction(
          1,
          'income',
          holding: null,
          target: 3,
          amount: 10,
          principal: 10,
        ),
      ]);
      expect(result.sampleCount, 0);
      expect(result.interruptionReason, '本金变化与相关持仓流水不一致');
    },
  );

  test('no-flow days also reject offsetting per-holding manual cost edits', () {
    final result = _estimate([
      _snapshot(0, [_value(1, 500, 500), _value(2, 500, 500)]),
      _snapshot(1, [_value(1, 500, 510), _value(2, 500, 490)]),
    ]);
    expect(result.sampleCount, 0);
    expect(result.interruptionReason, '本金变化与相关持仓流水不一致');
  });

  test(
    'foreign flows without recorded historical conversion cannot validate CNY principal',
    () {
      final result = _estimate(
        [
          _snapshot(0, [_value(1, 1000, 1000)]),
          _snapshot(1, [_value(1, 1700, 1700)]),
        ],
        [_transaction(1, 'buy', amount: 100, currency: 'USD')],
      );
      expect(result.sampleCount, 0);
      expect(result.interruptionReason, '交易流水缺少可核对的历史人民币折算');
    },
  );

  test(
    'an external sale requires recorded principal and matching realized gains',
    () {
      final values = [
        _snapshot(0, [_value(1, 110, 100)]),
        _snapshot(1, [_value(1, 0, 0, realized: 15)]),
      ];
      final missing = _estimate(values, [_transaction(1, 'sell', amount: 115)]);
      expect(missing.sampleCount, 0);
      expect(missing.interruptionReason, '交易流水的本金或关联持仓无法核对');
      final wrong = _estimate(
        [
          values.first,
          _snapshot(1, [_value(1, 0, 0, realized: 20)]),
        ],
        [_transaction(1, 'sell', amount: 115, externalPrincipal: 100)],
      );
      expect(wrong.sampleCount, 0);
      expect(wrong.interruptionReason, '已实现收益变化与卖出流水不一致');
    },
  );

  test(
    'edited flow snapshots remain blocked until rebuilt with a fresh timestamp',
    () {
      final inputs = _cashFlows(withReturn: true);
      final transactions = [...inputs.transactions];
      transactions[9] = transactions[9].copyWith(updatedAt: DateTime(2026, 2));
      final stale = _estimate(inputs.snapshots, transactions);
      expect(stale.sampleCount, 0);
      expect(stale.interruptionReason, '流水更新后尚未重建快照');
      final rebuilt = _estimate([
        for (final value in inputs.snapshots)
          value.copyWith(createdAt: DateTime(2026, 3)),
      ], transactions);
      expect(rebuilt.sampleCount, 40);
      expect(rebuilt.sharpe, isNotNull);
      expect(rebuilt.interruptionReason, isNull);
    },
  );

  test(
    'corrected cash withdrawals and debt repayments do not turn carried gains into losses',
    () {
      for (final repayment in [false, true]) {
        final values = <SnapshotRow>[];
        for (var day = 0; day <= 35; day++) {
          final closed = day >= 10;
          values.add(
            _snapshot(day, [
              _value(1, 100, 100),
              _value(
                2,
                closed ? 55 : 110,
                closed ? 50 : 100,
                type: AssetType.cash,
                adjustment: closed ? 5 : 0,
              ),
              if (repayment)
                _value(3, closed ? 5 : 60, 0, type: AssetType.liability),
            ]),
          );
        }
        final result = _estimate(values, [
          _transaction(
            10,
            repayment ? 'transfer_out' : 'expense',
            holding: null,
            source: repayment ? 2 : null,
            target: repayment ? 3 : 2,
            amount: 55,
            principal: 50,
          ),
        ]);
        expect(result.sampleCount, 35);
        expect(result.interruptionReason, isNull);
        expect(result.annualizedVolatility, 0);
      }
    },
  );

  test(
    'a corrected linked dividend remains usable without counting the cash twice',
    () {
      final values = <SnapshotRow>[];
      for (var day = 0; day <= 35; day++) {
        final paid = day >= 10;
        values.add(
          _snapshot(day, [
            _value(1, paid ? 100 : 110, paid ? 90 : 100),
            _value(
              2,
              paid ? 110 : 100,
              100,
              type: AssetType.cash,
              adjustment: paid ? -10 : 0,
            ),
          ]),
        );
      }
      final result = _estimate(values, [
        _transaction(10, 'dividend', target: 2, amount: 10, principal: 0),
      ]);
      expect(result.sampleCount, 35);
      expect(result.interruptionReason, isNull);
      expect(result.annualizedVolatility, 0);
    },
  );

  test(
    'standalone cash dividends remain investment income on their flow day',
    () {
      final values = [
        for (var day = 0; day <= 35; day++)
          _snapshot(day, [
            _value(1, day >= 10 ? 1010 : 1000, 1000, type: AssetType.cash),
          ]),
      ];
      final result = _estimate(values, [
        _transaction(
          10,
          'dividend',
          holding: null,
          target: 1,
          amount: 10,
          principal: 0,
        ),
      ]);
      expect(result.sampleCount, 35);
      expect(result.interruptionReason, isNull);
      expect(result.sharpe, closeTo(math.sqrt(365 / 35), 1e-10));
    },
  );

  test(
    'old dividend and cash-outflow snapshots require the corrected history marker',
    () {
      for (final dividend in [false, true]) {
        final before = _snapshot(0, [
          _value(1, 110, 100),
          _value(2, 100, 100, type: AssetType.cash),
        ]).copyWith(profitAdjustment: const Value(null));
        final after = _snapshot(1, [
          _value(1, dividend ? 100 : 110, dividend ? 90 : 100),
          _value(
            2,
            dividend ? 110 : 90,
            dividend ? 100 : 90,
            type: AssetType.cash,
          ),
        ]).copyWith(profitAdjustment: const Value(null));
        final result = _estimate(
          [before, after],
          [
            _transaction(
              1,
              dividend ? 'dividend' : 'expense',
              holding: dividend ? 1 : null,
              target: 2,
              amount: 10,
              principal: dividend ? 0 : 10,
            ),
          ],
        );
        expect(result.sampleCount, 0);
        expect(result.interruptionReason, '现金收支或分红快照仍为旧收益口径，请重建历史快照');
      }
    },
  );

  test(
    'offsetting hand-edited holding adjustments cannot hide behind an unchanged total',
    () {
      final result = _estimate([
        _snapshot(0, [_value(1, 500, 500), _value(2, 500, 500)]),
        _snapshot(1, [
          _value(1, 500, 500, adjustment: 10),
          _value(2, 500, 500, adjustment: -10),
        ]),
      ]);
      expect(result.sampleCount, 0);
      expect(result.interruptionReason, '持仓收益调整与相关流水不一致');
    },
  );

  test(
    'the recorded self-referencing liability opening keeps the risk series continuous',
    () {
      final values = [
        for (var day = 0; day <= 35; day++)
          _snapshot(day, [
            _value(1, 1000, 1000),
            if (day >= 10) _value(2, 60, 0, type: AssetType.liability),
          ]),
      ];
      final opening = _transaction(
        10,
        'transfer_out',
        holding: 2,
        source: 2,
        target: 2,
        amount: 60,
        principal: 60,
      ).copyWith(opensHolding: const Value(true));
      final result = _estimate(values, [opening]);
      expect(result.sampleCount, 35);
      expect(result.interruptionReason, isNull);
      expect(result.annualizedVolatility, 0);
    },
  );

  test(
    'a liability opening can be reconciled with consumption later on the same day',
    () {
      final opening = _transaction(
        1,
        'transfer_out',
        holding: 2,
        source: 2,
        target: 2,
        amount: 60,
        principal: 60,
        id: 1,
      ).copyWith(opensHolding: const Value(true));
      final result = _estimate(
        [
          _snapshot(0, [_value(1, 1000, 1000)]),
          _snapshot(1, [
            _value(1, 1000, 1000),
            _value(2, 70, 0, type: AssetType.liability),
          ]),
        ],
        [opening, _transaction(1, 'consume', holding: 2, amount: 10, id: 2)],
      );
      expect(result.sampleCount, 1);
      expect(result.interruptionReason, isNull);
    },
  );

  test(
    'ordinary self-transfers and inconsistent liability openings remain rejected',
    () {
      for (final kind in ['ordinary', 'cash', 'amount', 'existing', 'cost']) {
        final cash = kind == 'cash';
        final values = [
          _snapshot(0, [
            _value(1, 1000, 1000),
            if (kind == 'existing') _value(2, 10, 0, type: AssetType.liability),
          ]),
          _snapshot(1, [
            _value(1, 1000, 1000),
            _value(
              2,
              kind == 'amount' || kind == 'existing' ? 70 : 60,
              kind == 'cost' ? 1 : 0,
              type: cash ? AssetType.cash : AssetType.liability,
            ),
          ]),
        ];
        final flow = _transaction(
          1,
          'transfer_out',
          holding: 2,
          source: 2,
          target: 2,
          amount: 60,
          principal: 60,
        ).copyWith(opensHolding: Value(kind != 'ordinary'));
        final result = _estimate(values, [flow]);
        expect(result.sampleCount, 0, reason: kind);
        expect(result.interruptionReason, '交易流水的本金或关联持仓无法核对', reason: kind);
      }
    },
  );

  test(
    'cash holdings with an unrealized loss support verified withdrawals, borrowing and funded buys',
    () {
      for (final kind in ['expense', 'borrow', 'buy']) {
        final expense = kind == 'expense';
        final borrow = kind == 'borrow';
        final snapshots = [
          for (var day = 0; day <= 35; day++)
            _snapshot(day, [
              _value(
                1,
                day >= 10 && kind == 'buy' ? 140 : 100,
                day >= 10 && kind == 'buy' ? 150 : 100,
              ),
              _value(
                2,
                day < 10 ? 80 : (borrow ? 120 : 40),
                day < 10 ? 100 : (borrow ? 140 : 50),
                type: AssetType.cash,
                adjustment: day >= 10 && expense ? -10 : 0,
              ),
              if (borrow)
                _value(3, day >= 10 ? 40 : 0, 0, type: AssetType.liability),
            ]),
        ];
        final transaction = _transaction(
          10,
          expense ? 'expense' : (borrow ? 'transfer_out' : 'buy'),
          holding: kind == 'buy' ? 1 : null,
          source: borrow ? 3 : (kind == 'buy' ? 2 : null),
          target: kind == 'buy' ? null : 2,
          amount: 40,
          principal: borrow ? 40 : 50,
        );
        final result = _estimate(snapshots, [transaction]);
        expect(result.sampleCount, 35, reason: kind);
        expect(result.interruptionReason, isNull, reason: kind);
        expect(result.annualizedVolatility, 0, reason: kind);
      }
    },
  );
}
