import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';

HoldingRow _holding({
  required int id,
  required String type,
  String? symbol,
  double quantity = 1,
  double price = 100,
  double cost = 90,
}) {
  return HoldingRow(
    id: id,
    accountId: 1,
    name: 'h$id',
    assetType: type,
    marketSource: 'manual',
    symbol: symbol,
    quantity: quantity,
    costPrice: cost,
    latestPrice: price,
    currency: 'CNY',
    note: null,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

void main() {
  const calc = PortfolioCalculator();

  test('empty holdings -> zero summary', () {
    final s = calc.compute([]);
    expect(s.netWorth, 0);
    expect(s.totalAssets, 0);
    expect(s.profit, 0);
    expect(s.breakdown, isEmpty);
  });

  test('computes assets, cost and profit', () {
    final s = calc.compute([
      _holding(id: 1, type: 'stock', quantity: 2, price: 150, cost: 100),
      _holding(id: 2, type: 'mutual_fund', quantity: 1, price: 50, cost: 60),
    ]);
    expect(s.totalAssets, 350);
    expect(s.totalCost, 260);
    expect(s.profit, 90);
    expect(s.profitPct, closeTo(90 / 260, 1e-9));
    expect(s.totalLiabilities, 0);
  });

  test('liabilities reduce net worth but not assets', () {
    final s = calc.compute([
      _holding(id: 1, type: 'cash', price: 500, cost: 500),
      _holding(id: 2, type: 'liability', price: 200, cost: 200),
    ]);
    expect(s.totalAssets, 500);
    expect(s.totalLiabilities, 200);
    expect(s.netWorth, 300);
  });

  test('breakdown is sorted desc and grouped by type', () {
    final s = calc.compute([
      _holding(id: 1, type: 'stock', price: 100, cost: 90),
      _holding(id: 2, type: 'stock', price: 50, cost: 40),
      _holding(id: 3, type: 'mutual_fund', price: 200, cost: 150),
      _holding(id: 4, type: 'liability', price: 999, cost: 999),
    ]);
    expect(s.breakdown.map((b) => b.type.storageName).toList(), ['mutual_fund', 'stock']);
    expect(s.breakdown.first.marketValue, 200);
  });

  test('today change uses cached previous prices', () {
    final s = calc.compute(
      [
        _holding(id: 1, type: 'stock', symbol: 'sh600519', quantity: 2, price: 110, cost: 100),
        _holding(id: 2, type: 'cash', price: 100, cost: 100),
      ],
      prevPriceBySymbol: {'sh600519': 100},
    );
    expect(s.todayChange, 20);
    expect(s.todayChangePct, closeTo(20 / 200, 1e-9));
  });

  test('today change skips holdings without previous price', () {
    final s = calc.compute(
      [_holding(id: 1, type: 'stock', symbol: 'sh600519', price: 110, cost: 100)],
    );
    expect(s.todayChange, 0);
    expect(s.todayChangePct, isNull);
  });
}
