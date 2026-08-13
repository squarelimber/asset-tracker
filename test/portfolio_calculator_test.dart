import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;

HoldingRow _holding({
  required int id,
  required String type,
  String? symbol,
  double quantity = 1,
  double price = 100,
  double cost = 90,
  String currency = 'CNY',
  double? costFxRate,
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
    currency: currency,
    costFxRate: costFxRate,
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
      // Amount-based cash: quantity = 500 amount, costPrice = 500 invested.
      _holding(id: 1, type: 'cash', quantity: 500, price: 1, cost: 500),
      _holding(id: 2, type: 'liability', price: 200, cost: 200),
    ]);
    expect(s.totalAssets, 500);
    expect(s.totalLiabilities, 200);
    expect(s.netWorth, 300);
  });

  test('amount-based assets use quantity as value and costPrice as invested', () {
    final s = calc.compute([
      // 10,000 yuan balance, 9,000 invested -> 1,000 profit.
      _holding(id: 1, type: 'cash', quantity: 10000, price: 0, cost: 9000),
      // No invested amount recorded -> cost falls back to current amount.
      _holding(id: 2, type: 'liquid_wealth', quantity: 5000, price: 0, cost: 0),
    ]);
    expect(s.totalAssets, 15000);
    expect(s.totalCost, 14000);
    expect(s.profit, 1000);
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
        _holding(id: 2, type: 'cash', quantity: 100, price: 1, cost: 100),
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

  test('non-CNY holdings are converted into CNY', () {
    final s = calc.compute(
      [
        _holding(id: 1, type: 'stock', price: 100, cost: 80), // CNY
        _holding(id: 2, type: 'cash', quantity: 1000, price: 1, cost: 1000)
            .copyWith(currency: 'USD'), // USD cash
      ],
      cnyRates: {'USD': 7.2},
    );
    // 100 CNY + 1000 USD * 7.2 = 7300 CNY.
    expect(s.totalAssets, closeTo(7300, 1e-6));
    expect(s.totalCost, closeTo(80 + 7200, 1e-6));
  });

  test('realized profit sums sell gains using current unit cost', () {
    final s = calc.compute(
      [
        _holding(id: 1, type: 'stock', quantity: 100, price: 20, cost: 10),
      ],
      sellTransactions: [
        TransactionRow(
          id: 1,
          accountId: 1,
          holdingId: 1,
          cashSourceId: null,
          cashTargetId: null,
          type: 'sell',
          quantity: 50,
          price: 15,
          amount: 750,
          currency: 'CNY',
          occurredAt: DateTime(2026, 1, 1),
          note: null,
          costMoved: true,
        ),
      ],
    );
    // (15 - 10) * 50 = 250 realized; total profit = (20-10)*100 = 1000.
    expect(s.realizedProfit, closeTo(250, 1e-6));
    expect(s.unrealizedProfit, closeTo(750, 1e-6));
  });

  test('risk breakdown groups holdings by effective risk tier', () {
    final s = calc.compute([
      _holding(id: 1, type: 'cash', quantity: 1000, price: 1, cost: 1000),
      _holding(id: 2, type: 'mutual_fund', price: 300, cost: 250),
      _holding(id: 3, type: 'stock', price: 600, cost: 500),
    ]);
    expect(s.riskBreakdown, hasLength(3));
    final low = s.riskBreakdown.firstWhere((b) => b.risk == RiskLevel.low);
    expect(low.marketValue, 1000);
    final medium = s.riskBreakdown.firstWhere((b) => b.risk == RiskLevel.medium);
    expect(medium.marketValue, 300);
    final high = s.riskBreakdown.firstWhere((b) => b.risk == RiskLevel.high);
    expect(high.marketValue, 600);
  });

  test('manual risk override wins over auto mapping', () {
    final manual = _holding(id: 1, type: 'mutual_fund', price: 300, cost: 250)
        .copyWith(riskLevel: const Value('low'));
    final s = calc.compute([manual]);
    final low = s.riskBreakdown.firstWhere((b) => b.risk == RiskLevel.low);
    expect(low.marketValue, 300);
  });

  test('foreign cost uses the recorded purchase rate, value the current rate', () {
    final s = calc.compute(
      [
        _holding(
          id: 1,
          type: 'mutual_fund',
          quantity: 100,
          price: 2,
          cost: 1.5,
          currency: 'USD',
          costFxRate: 6.95,
        ),
      ],
      cnyRates: const {'USD': 7.2},
    );
    // Value: 100 x 2 x 7.2 = 1440; cost: 100 x 1.5 x 6.95 = 1042.5.
    expect(s.totalAssets, closeTo(1440, 1e-6));
    expect(s.totalCost, closeTo(1042.5, 1e-6));
    expect(s.profit, closeTo(397.5, 1e-6));
  });

  test('foreign cost falls back to the current rate without a recorded one', () {
    final s = calc.compute(
      [
        _holding(
          id: 1,
          type: 'mutual_fund',
          quantity: 100,
          price: 2,
          cost: 1.5,
          currency: 'USD',
        ),
      ],
      cnyRates: const {'USD': 7.2},
    );
    expect(s.totalCost, closeTo(1080, 1e-6)); // 100 x 1.5 x 7.2
  });
}
