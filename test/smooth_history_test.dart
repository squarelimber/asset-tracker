import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/smooth_history.dart';

HoldingRow _amountHolding({
  double quantity = 1000,
  double cost = 1000,
}) {
  return HoldingRow(
    id: 1,
    accountId: 1,
    name: '现金',
    assetType: 'bank_deposit',
    marketSource: 'manual',
    symbol: null,
    quantity: quantity,
    costPrice: cost,
    latestPrice: 1,
    purchaseDate: DateTime(2026, 1, 1),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    currency: 'CNY',
    costFxRate: null,
    riskLevel: null,
    note: null,
  );
}

TransactionRow _income({
  required int id,
  required DateTime at,
  required double amount,
  required int targetId,
}) {
  return TransactionRow(
    id: id,
    accountId: 1,
    holdingId: null,
    cashSourceId: null,
    cashTargetId: targetId,
    type: 'income',
    quantity: null,
    price: null,
    amount: amount,
    currency: 'CNY',
    occurredAt: at,
    note: null,
    costMoved: true,
    updatedAt: at,
  );
}

void main() {
  const calc = SmoothHistoryCalculator();

  test('geometric interpolate hits start, middle and end', () {
    expect(geometricInterpolate(100, 121, 0, 10), closeTo(100, 1e-9));
    expect(geometricInterpolate(100, 121, 10, 10), closeTo(121, 1e-9));
    // Halfway: sqrt(100*121) = 110.
    expect(geometricInterpolate(100, 121, 5, 10), closeTo(110, 1e-6));
  });

  test('no flows: value grows smoothly from cost to balance', () {
    final h = _amountHolding(quantity: 1210, cost: 1000); // gain 210
    final map = calc.amountHistory(
      h,
      const [],
      from: DateTime(2026, 1, 1),
      to: DateTime(2026, 1, 11), // 10 days
    );
    expect(map['2026-01-01'], closeTo(1000, 1e-6));
    expect(map['2026-01-11'], closeTo(1210, 1e-6));
    expect(map['2026-01-06'], closeTo(1100, 0.01)); // geometric midpoint
  });

  test('income mid-way creates a jump and keeps both ends real', () {
    final h = _amountHolding(quantity: 3200, cost: 3000); // gain 200
    // 1/5 income +1000: principal 2000 -> 3000.
    final flows = [
      _income(id: 1, at: DateTime(2026, 1, 5), amount: 1000, targetId: 1),
    ];
    final map = calc.amountHistory(
      h,
      flows,
      from: DateTime(2026, 1, 1),
      to: DateTime(2026, 1, 11),
    );
    // Day before income: below 2000 + allocated gain for segment 1.
    final before = map['2026-01-04']!;
    final after = map['2026-01-05']!;
    // The income day jumps up by ~1000 (segment boundary).
    expect(after - before, closeTo(1000, 20));
    // Ends remain exact.
    expect(map['2026-01-01'], closeTo(2000, 1e-6)); // initial principal
    expect(map['2026-01-11'], closeTo(3200, 1e-6));
  });

  test('transfer with costMoved=false does not shift the principal', () {
    final h = _amountHolding(quantity: 1050, cost: 1000);
    final legacy = TransactionRow(
      id: 2,
      accountId: 1,
      holdingId: null,
      cashSourceId: 1,
      cashTargetId: 2,
      type: 'transfer_out',
      quantity: null,
      price: null,
      amount: 300,
      currency: 'CNY',
      occurredAt: DateTime(2026, 1, 5),
      note: null,
      costMoved: false,
      updatedAt: DateTime(2026, 1, 5),
    );
    final map = calc.amountHistory(
      h,
      [legacy],
      from: DateTime(2026, 1, 1),
      to: DateTime(2026, 1, 11),
    );
    // Legacy transfer does not move the invested amount: no jump.
    expect(map['2026-01-04']!, closeTo(map['2026-01-05']!, 5));
  });

  test('share price interpolates from cost to latest', () {
    final h = HoldingRow(
      id: 3,
      accountId: 1,
      name: '月月盈',
      assetType: 'bank_wealth',
      marketSource: 'manual',
      symbol: null,
      quantity: 1000,
      costPrice: 1.0,
      latestPrice: 1.21,
      purchaseDate: DateTime(2026, 1, 1),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      currency: 'CNY',
      costFxRate: null,
      riskLevel: null,
      note: null,
    );
    final from = DateTime(2026, 1, 1);
    final to = DateTime(2026, 1, 11);
    expect(calc.sharePrice(h, DateTime(2026, 1, 1), from, to), closeTo(1.0, 1e-9));
    expect(calc.sharePrice(h, DateTime(2026, 1, 11), from, to), closeTo(1.21, 1e-9));
    expect(calc.sharePrice(h, DateTime(2026, 1, 6), from, to), closeTo(1.10, 1e-6));
  });

  test('amountPrincipal without flows is the current cost every day', () {
    final h = _amountHolding(quantity: 90558, cost: 90558);
    final map = calc.amountPrincipal(
      h,
      const [],
      from: DateTime(2026, 1, 1),
      to: DateTime(2026, 1, 11),
    );
    expect(map['2026-01-01'], closeTo(90558, 1e-6));
    expect(map['2026-01-11'], closeTo(90558, 1e-6));
  });

  test('amountPrincipal keeps the pre-repayment principal before the flow', () {
    final h = _amountHolding(quantity: 90558, cost: 90558);
    // 1/5 repay 5514: principal 96072 -> 90558.
    final repay = TransactionRow(
      id: 4,
      accountId: 1,
      holdingId: null,
      cashSourceId: 1,
      cashTargetId: 2,
      type: 'transfer_out',
      quantity: null,
      price: null,
      amount: 5514,
      currency: 'CNY',
      occurredAt: DateTime(2026, 1, 5),
      note: null,
      costMoved: true,
      updatedAt: DateTime(2026, 1, 5),
    );
    final map = calc.amountPrincipal(
      h,
      [repay],
      from: DateTime(2026, 1, 1),
      to: DateTime(2026, 1, 11),
    );
    expect(map['2026-01-01'], closeTo(96072, 1e-6));
    expect(map['2026-01-04'], closeTo(96072, 1e-6));
    expect(map['2026-01-05'], closeTo(90558, 1e-6));
    expect(map['2026-01-11'], closeTo(90558, 1e-6));
  });

  test('amountPrincipal ignores transfers that did not move the cost', () {
    final h = _amountHolding(quantity: 1050, cost: 1000);
    final legacy = TransactionRow(
      id: 5,
      accountId: 1,
      holdingId: null,
      cashSourceId: 1,
      cashTargetId: 2,
      type: 'transfer_out',
      quantity: null,
      price: null,
      amount: 300,
      currency: 'CNY',
      occurredAt: DateTime(2026, 1, 5),
      note: null,
      costMoved: false,
      updatedAt: DateTime(2026, 1, 5),
    );
    final map = calc.amountPrincipal(
      h,
      [legacy],
      from: DateTime(2026, 1, 1),
      to: DateTime(2026, 1, 11),
    );
    expect(map['2026-01-01'], closeTo(1000, 1e-6));
    expect(map['2026-01-05'], closeTo(1000, 1e-6));
    expect(map['2026-01-11'], closeTo(1000, 1e-6));
  });
}
