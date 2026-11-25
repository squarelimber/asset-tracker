import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/cash_flow_adjustments.dart';
import 'package:asset_tracker/domain/daily_earnings.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:flutter_test/flutter_test.dart';

DayHoldingValue _value(
  int id,
  double value,
  double cost, {
  bool share = false,
}) => DayHoldingValue(
  holdingId: id,
  name: '产品$id',
  type: share ? AssetType.etf : AssetType.cash,
  value: value,
  cost: cost,
  liability: false,
);

SnapshotRow _snapshot(int day, List<DayHoldingValue> values) => SnapshotRow(
  date: '2026-07-${day.toString().padLeft(2, '0')}',
  currency: 'CNY',
  totalValue: values.fold(0.0, (sum, value) => sum + value.value),
  totalCost: values.fold(0.0, (sum, value) => sum + value.cost),
  liabilities: 0,
  profitAdjustment: 0,
  holdingValues: encodeHoldingValues(values),
  createdAt: DateTime(2026, 7, day, 16),
);

TransactionRow _flow({
  int id = 1,
  String type = 'dividend',
  int? holding = 1,
  int? source,
  int? target = 2,
  double amount = 100,
  double? principal,
  String currency = 'CNY',
}) => TransactionRow(
  id: id,
  accountId: 1,
  type: type,
  holdingId: holding,
  cashSourceId: source,
  cashTargetId: target,
  amount: amount,
  quantity: type == 'buy' ? 100 : null,
  costMovedAmount: principal,
  currency: currency,
  costMoved: true,
  internalMove: false,
  occurredAt: DateTime(2026, 7, 7, 12),
  updatedAt: DateTime(2026, 7, 7, 12),
);

void main() {
  test('offsetting cumulative adjustments require the previous holding details', () {
    final recorded = _snapshot(6, [
      _value(1, 100, 100).withProfitAdjustment(50),
      _value(2, 100, 100).withProfitAdjustment(-50),
    ]);
    final current = _snapshot(7, [
      _value(1, 100, 100),
      _value(2, 100, 100),
    ]);
    final carried = cashFlowAdjustmentsBetween(
      recorded, current, transactions: [],
    );
    expect(carried.verified, isTrue, reason: carried.issue);
    expect(carried.total, 0);
    expect(carried.byHolding, {1: 50, 2: -50});

    for (final payload in <String?>[null, 'invalid payload']) {
      final previous = SnapshotRow(
        date: recorded.date,
        currency: recorded.currency,
        totalValue: recorded.totalValue,
        totalCost: recorded.totalCost,
        liabilities: recorded.liabilities,
        profitAdjustment: 0,
        holdingValues: payload,
        createdAt: recorded.createdAt,
      );
      final result = cashFlowAdjustmentsBetween(
        previous, current, transactions: [],
      );
      expect(result.verified, isFalse);
      expect(result.issue, contains('累计收益调整明细'));
      expect(() => result.applyTo(current), throwsStateError);
    }
  });

  test(
    'a documented first buy supplies a zero opening cost for a same-day dividend',
    () {
      final previous = _snapshot(6, [_value(2, 1000, 1000)]);
      final current = _snapshot(7, [
        _value(1, 900, 900, share: true),
        _value(2, 1100, 1000),
      ]);
      final result = cashFlowAdjustmentsBetween(
        previous,
        current,
        transactions: [
          _flow(id: 1, type: 'buy', amount: 1000, target: null),
          _flow(id: 2),
        ],
      );
      expect(result.verified, isTrue, reason: result.issue);
      expect(result.total, -100);
      expect(
        snapshotAssetProfit(result.applyTo(current)),
        snapshotAssetProfit(previous),
      );
    },
  );

  test('a first buy cannot replace a missing opening snapshot payload', () {
    final previous = SnapshotRow(
      date: '2026-07-06',
      currency: 'CNY',
      totalValue: 1000,
      totalCost: 1000,
      liabilities: 0,
      createdAt: DateTime(2026, 7, 6, 16),
    );
    final current = _snapshot(7, [
      _value(1, 900, 900, share: true),
      _value(2, 1100, 1000),
    ]);
    final result = cashFlowAdjustmentsBetween(
      previous,
      current,
      transactions: [
        _flow(id: 1, type: 'buy', amount: 1000, target: null),
        _flow(id: 2),
      ],
    );
    expect(result.verified, isFalse);
    expect(result.issue, contains('成本明细'));
  });

  test(
    'a capped share-cost reduction corrects only the actual cost removed',
    () {
      final previous = _snapshot(6, [
        _value(1, 100, 50, share: true),
        _value(2, 100, 100),
      ]);
      final current = _snapshot(7, [
        _value(1, 0, 0, share: true),
        _value(2, 200, 100),
      ]);
      final result = cashFlowAdjustmentsBetween(
        previous,
        current,
        transactions: [_flow()],
      );
      expect(result.verified, isTrue, reason: result.issue);
      expect(result.byHolding, {1: 50, 2: -100});
      expect(result.total, -50);
      expect(
        snapshotAssetProfit(result.applyTo(current)),
        snapshotAssetProfit(previous),
      );
    },
  );

  test(
    'a linked dividend with a missing source or cash target needs verification',
    () {
      for (final values in [
        [_value(2, 100, 100)],
        [_value(1, 1000, 900, share: true)],
      ]) {
        final result = cashFlowAdjustmentsBetween(
          _snapshot(6, values),
          _snapshot(7, values),
          transactions: [_flow()],
        );
        expect(result.verified, isFalse);
        expect(result.issue, contains('关联分红'));
      }
    },
  );

  test(
    'missing cash outflow or transfer identities are not treated as a verified zero',
    () {
      final previous = _snapshot(6, [_value(2, 120, 100)]);
      final current = _snapshot(7, [_value(2, 60, 50)]);
      for (final row in [
        _flow(
          type: 'expense',
          holding: null,
          target: 999,
          amount: 60,
          principal: 50,
        ),
        _flow(
          type: 'transfer_out',
          holding: null,
          source: 2,
          target: 999,
          amount: 60,
          principal: 50,
        ),
      ]) {
        final result = cashFlowAdjustmentsBetween(
          previous,
          current,
          transactions: [row],
        );
        expect(result.verified, isFalse);
        expect(result.issue, contains('持仓明细'));
      }
    },
  );

  test(
    'equal native-currency principal can still carry an unverified FX gain',
    () {
      final previous = _snapshot(6, [_value(2, 710, 700)]);
      final current = _snapshot(7, [_value(2, 355, 350)]);
      final result = cashFlowAdjustmentsBetween(
        previous,
        current,
        transactions: [
          _flow(
            type: 'expense',
            holding: null,
            amount: 50,
            principal: 50,
            currency: 'USD',
          ),
        ],
      );
      expect(result.verified, isFalse);
      expect(result.issue, contains('USD'));
    },
  );
}
