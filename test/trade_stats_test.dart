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
    currency: 'CNY',
    occurredAt: at ?? DateTime(2026, 8, 1),
    note: null,
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
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ),
    ]);
    expect(stats.realizedProfit, closeTo(250, 1e-6));
  });
}
