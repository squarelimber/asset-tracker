import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/trade_stats.dart';

TransactionRow _txn({
  required int id,
  required String type,
  int? holdingId,
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
    cashSourceId: null,
    cashTargetId: null,
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

void main() {
  const calc = TradeStatsCalculator();

  test('totals by type and net cashflow', () {
    final stats = calc.compute([
      _txn(id: 1, type: 'income', amount: 10000, at: DateTime(2026, 8, 1)),
      _txn(id: 2, type: 'expense', amount: 2000, at: DateTime(2026, 8, 2)),
      _txn(id: 3, type: 'buy', amount: 5000, at: DateTime(2026, 8, 3)),
      _txn(id: 4, type: 'sell', amount: 8000, at: DateTime(2026, 8, 4)),
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
