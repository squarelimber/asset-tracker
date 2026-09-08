import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/trade_stats.dart';

TransactionRow _txn({
  required int id,
  required String type,
  int? holdingId,
  int? cashSourceId,
  int? cashTargetId,
  double amount = 0,
  double? quantity,
  double? price,
  String currency = 'CNY',
  DateTime? at,
}) {
  return TransactionRow(
    id: id,
    accountId: 1,
    holdingId: holdingId,
    cashSourceId: cashSourceId,
    cashTargetId: cashTargetId,
    type: type,
    quantity: quantity,
    price: price,
    amount: amount,
    currency: currency,
    occurredAt: at ?? DateTime(2026, 8, 1),
    note: null,
    costMoved: true,
    updatedAt: at ?? DateTime(2026, 8, 1),
  );
}

HoldingRow _holding({
  required int id,
  required String type,
  double quantity = 0,
  double cost = 0,
  double price = 1,
}) {
  return HoldingRow(
    id: id,
    accountId: 1,
    name: 'h$id',
    assetType: type,
    marketSource: 'manual',
    symbol: null,
    quantity: quantity,
    costPrice: cost,
    latestPrice: price,
    currency: 'CNY',
    note: null,
    archived: false,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

void main() {
  const calc = TradeStatsCalculator();

  test('totals by type and net cashflow', () {
    final stats = calc.compute([
      _txn(id: 1, type: 'income', amount: 10000, at: DateTime(2026, 8, 1)),
      _txn(id: 2, type: 'expense', amount: 2000, at: DateTime(2026, 8, 2)),
      _txn(id: 3, type: 'buy', amount: 5000, cashSourceId: 9, at: DateTime(2026, 8, 3)),
      _txn(id: 4, type: 'sell', amount: 8000, cashTargetId: 9, at: DateTime(2026, 8, 4)),
      _txn(id: 5, type: 'dividend', amount: 300, at: DateTime(2026, 8, 5)),
    ], const []);
    expect(stats.incomeTotal, 10000);
    expect(stats.expenseTotal, 2000);
    expect(stats.boughtTotal, 5000);
    expect(stats.soldTotal, 8000);
    expect(stats.dividendTotal, 300);
    // 10000 + 8000 + 300 - 2000 - 5000 = 11300
    expect(stats.cashflow, 11300);
  });

  test('buys and sells without cash linkage are internal movements', () {
    // Redemption funding another holding: a sell without a cash target and
    // a buy without a cash source. Neither touches the cash balance.
    final stats = calc.compute([
      _txn(id: 1, type: 'sell', holdingId: 11, amount: 5000, at: DateTime(2026, 9, 8)),
      _txn(id: 2, type: 'buy', holdingId: 51, amount: 5000, at: DateTime(2026, 9, 8)),
    ], const []);
    expect(stats.boughtTotal, 0);
    expect(stats.soldTotal, 0);
    expect(stats.cashflow, 0);
    expect(stats.monthlyCashflow, isEmpty);
  });

  test('standalone redemption (no cash target) does not affect cashflow', () {
    final stats = calc.compute([
      _txn(id: 1, type: 'sell', holdingId: 11, amount: 49999.075, at: DateTime(2026, 9, 8)),
    ], const []);
    expect(stats.soldTotal, 0);
    expect(stats.realizedProfit, 0);
    expect(stats.cashflow, 0);
    expect(stats.monthlyCashflow, isEmpty);
  });

  test('amount-based sell contributes zero realized profit', () {
    // 天天宝-style bank deposit: costPrice is the cumulative invested
    // amount (115,399.71), not a unit cost. A redemption of 49,999.075
    // @ 1.0 must not produce (1.0 - 115399.71) x 49999.075.
    final stats = calc.compute(
      [
        _txn(
          id: 1,
          type: 'sell',
          holdingId: 11,
          amount: 49999.075,
          quantity: 49999.075,
          price: 1.0,
          at: DateTime(2026, 9, 8),
        ),
      ],
      [
        _holding(id: 11, type: 'bank_deposit', quantity: 117338.20, cost: 115399.71),
      ],
    );
    expect(stats.realizedProfit, 0);
    // No cash target: not counted as a sell either.
    expect(stats.soldTotal, 0);
    expect(stats.cashflow, 0);
  });

  test('sell to cash is counted in cashflow and still realizes', () {
    final stats = calc.compute(
      [
        _txn(
          id: 1,
          type: 'sell',
          holdingId: 1,
          amount: 750,
          quantity: 50,
          price: 15,
          cashTargetId: 9,
        ),
      ],
      [
        _holding(id: 1, type: 'mutual_fund', quantity: 100, cost: 10, price: 15),
      ],
    );
    expect(stats.soldTotal, 750);
    expect(stats.monthlyCashflow['2026-08'], 750);
    expect(stats.realizedProfit, closeTo(250, 1e-6));
  });

  test('transfers do not affect cashflow', () {
    final stats = calc.compute([
      _txn(id: 1, type: 'transferOut', amount: 3000),
      _txn(id: 2, type: 'income', amount: 1000),
    ], const []);
    expect(stats.cashflow, 1000);
  });

  test('monthly cashflow is bucketed by month', () {
    final stats = calc.compute([
      _txn(id: 1, type: 'income', amount: 5000, at: DateTime(2026, 7, 15)),
      _txn(id: 2, type: 'expense', amount: 1000, at: DateTime(2026, 7, 20)),
      _txn(id: 3, type: 'income', amount: 6000, at: DateTime(2026, 8, 1)),
    ], const []);
    expect(stats.monthlyCashflow['2026-07'], 4000);
    expect(stats.monthlyCashflow['2026-08'], 6000);
  });

  test('realized profit from sells uses current unit cost', () {
    final stats = calc.compute([
      _txn(id: 1, type: 'sell', holdingId: 1, amount: 750, quantity: 50, price: 15),
    ], [
      HoldingRow(
        id: 1,
        accountId: 1,
        name: '基金',
        assetType: 'mutual_fund',
        marketSource: 'eastmoney',
        symbol: '110022',
        quantity: 100,
        costPrice: 10,
        latestPrice: 15,
        currency: 'CNY',
        note: null,
        archived: false,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ),
    ]);
    expect(stats.realizedProfit, closeTo(250, 1e-6));
  });

  test('foreign currency amounts are converted into CNY', () {
    final stats = calc.compute([
      _txn(id: 1, type: 'income', amount: 1000, currency: 'USD', at: DateTime(2026, 8, 1)),
      _txn(id: 2, type: 'expense', amount: 2000, currency: 'CNY', at: DateTime(2026, 8, 2)),
    ], const [], cnyRates: {'USD': 7.2});
    // 1000*7.2 - 2000 = 5200
    expect(stats.cashflow, closeTo(5200, 1e-6));
    expect(stats.incomeTotal, closeTo(7200, 1e-6));
  });

  test('realizedProfitByHolding sums sells per holding', () {
    final byHolding = TradeStatsCalculator.realizedProfitByHolding([
      _txn(id: 1, type: 'sell', holdingId: 1, quantity: 50, price: 15),
      _txn(id: 2, type: 'sell', holdingId: 1, quantity: 30, price: 20),
      _txn(id: 3, type: 'sell', holdingId: 2, quantity: 10, price: 4),
      _txn(id: 4, type: 'buy', holdingId: 1, quantity: 5, price: 12), // ignored
      _txn(id: 5, type: 'dividend', holdingId: 1, amount: 10), // ignored
    ], {1: 10, 2: 5});
    // holding 1: (15-10)*50 + (20-10)*30 = 250 + 300 = 550
    expect(byHolding[1], closeTo(550, 1e-6));
    // holding 2: (4-5)*10 = -10
    expect(byHolding[2], closeTo(-10, 1e-6));
    expect(byHolding, hasLength(2));
  });

  test('realizedProfitByHolding converts foreign currency to CNY', () {
    final byHolding = TradeStatsCalculator.realizedProfitByHolding([
      _txn(id: 1, type: 'sell', holdingId: 7, quantity: 10, price: 2, currency: 'USD'),
    ], {7: 1}, cnyRates: {'USD': 7});
    // (2-1)*10*7 = 70
    expect(byHolding[7], closeTo(70, 1e-6));
  });

  test('realizedProfitByHolding skips amount-based holdings', () {
    final byHolding = TradeStatsCalculator.realizedProfitByHolding(
      [
        // Redemption of an amount-based holding: costPrice is the invested
        // total, so the realized profit must be exactly 0.
        _txn(id: 1, type: 'sell', holdingId: 11, quantity: 49999.075, price: 1.0),
        _txn(id: 2, type: 'sell', holdingId: 1, quantity: 50, price: 15),
      ],
      {11: 115399.71, 1: 10},
      amountBasedHoldingIds: {11},
    );
    expect(byHolding, hasLength(1));
    expect(byHolding[11], isNull);
    expect(byHolding[1], closeTo(250, 1e-6));
  });

  test('lastSellDate picks the newest sell, optionally per holding', () {
    final txns = [
      _txn(id: 1, type: 'sell', holdingId: 1, at: DateTime(2026, 3, 1)),
      _txn(id: 2, type: 'sell', holdingId: 2, at: DateTime(2026, 5, 1)),
      _txn(id: 3, type: 'sell', holdingId: 1, at: DateTime(2026, 4, 1)),
      _txn(id: 4, type: 'buy', holdingId: 1, at: DateTime(2026, 6, 1)),
    ];
    expect(TradeStatsCalculator.lastSellDate(txns), DateTime(2026, 5, 1));
    expect(TradeStatsCalculator.lastSellDate(txns, holdingId: 1), DateTime(2026, 4, 1));
    expect(TradeStatsCalculator.lastSellDate(txns, holdingId: 99), isNull);
    expect(TradeStatsCalculator.lastSellDate(const []), isNull);
  });
}
