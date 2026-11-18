import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';

HoldingRow _holding({
  int id = 1,
  String name = '基金A',
  double quantity = 0,
  double costPrice = 0,
  double latestPrice = 0,
}) {
  return HoldingRow(costRecorded: false, 
    id: id,
    accountId: 1,
    name: name,
    assetType: 'mutual_fund',
    marketSource: 'eastmoney',
    symbol: '110022',
    quantity: quantity,
    costPrice: costPrice,
    latestPrice: latestPrice,
    currency: 'CNY',
    purchaseDate: DateTime(2026, 1, 1),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    costFxRate: null,
    riskLevel: null,
    note: null,
    archived: false,
  );
}

TransactionRow _txn({
  required int id,
  required String type,
  required DateTime at,
  double amount = 0,
  double? quantity,
  int holdingId = 1,
  double? costMovedAmount,
  bool internalMove = false,
}) {
  return TransactionRow(
    id: id,
    accountId: 1,
    holdingId: holdingId,
    cashSourceId: null,
    cashTargetId: null,
    type: type,
    quantity: quantity,
    price: null,
    amount: amount,
    currency: 'CNY',
    occurredAt: at,
    note: null,
    costMoved: true,
    internalMove: internalMove,
    costMovedAmount: costMovedAmount,
    updatedAt: at,
  );
}

void main() {
  const replay = HoldingReplay();
  const calc = ProductEarningsCalculator();

  group('HoldingReplay', () {
    test('same-day liquidation and repurchase follow transaction timestamps', () {
      final captured = <int, double>{};
      final history = replay.replay(
        _holding(quantity: 20, costPrice: 4),
        [
          _txn(id: 1, type: 'buy', at: DateTime(2026, 1, 1), amount: 100, quantity: 100),
          _txn(id: 2, type: 'buy', at: DateTime(2026, 1, 3, 15), amount: 80, quantity: 20),
          _txn(id: 3, type: 'sell', at: DateTime(2026, 1, 3, 10), amount: 150, quantity: 100),
        ],
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 1, 4),
        capturedSellPrincipal: captured,
      );
      expect(history['2026-01-02'], (100.0, 100.0));
      expect(history['2026-01-03'], (20.0, 80.0));
      expect(captured[3], 100);
    });

    test('cashless funded buy replays the transferred principal, including zero', () {
      for (final principal in [0.0, 120.0]) {
        final history = replay.replay(
          _holding(quantity: 10, costPrice: principal / 10),
          [
            _txn(id: 1, type: 'buy', at: DateTime(2026, 1, 3), amount: 150,
                quantity: 10, costMovedAmount: principal, internalMove: true),
          ],
          from: DateTime(2026, 1, 2),
          to: DateTime(2026, 1, 4),
        );
        expect(history['2026-01-02'], (0.0, 0.0));
        expect(history['2026-01-03'], (10.0, principal));
      }
    });

    test('legacy full sale uses the stored cost of an opening position', () {
      final captured = <int, double>{};
      final history = replay.replay(
        _holding(quantity: 0, costPrice: 9),
        [_txn(id: 1, type: 'sell', at: DateTime(2026, 1, 3), amount: 1200, quantity: 100)],
        from: DateTime(2026, 1, 2),
        to: DateTime(2026, 1, 4),
        capturedSellPrincipal: captured,
      );
      expect(history['2026-01-02'], (100.0, 900.0));
      expect(history['2026-01-03'], (0.0, 0.0));
      expect(captured[1], 900);
    });

    test('full sale removes replay residue once the closing flow is included', () {
      const buys = [8863.74899101498, 9371.783504209357, 7110.385593650861];
      final flows = [
        for (final (index, qty) in buys.indexed)
          _txn(id: index + 1, type: 'buy', at: DateTime(2026, 1, index + 1),
              amount: qty, quantity: qty),
        _txn(id: 4, type: 'sell', at: DateTime(2026, 1, 4),
            amount: 30000, quantity: 25345.918088875198),
      ];
      final history = replay.replay(_holding(), flows,
          from: DateTime(2026, 1, 3), to: DateTime(2026, 1, 5));
      expect(history['2026-01-03']!.$1, closeTo(25345.918088875198, 1e-9));
      expect(history['2026-01-04'], (0.0, 0.0));
      expect(history['2026-01-05'], (0.0, 0.0));
    });

    test('simple buy keeps the position across the window', () {
      final h = _holding(quantity: 100, costPrice: 10);
      final r = replay.replay(
        h,
        [_txn(id: 1, type: 'buy', at: DateTime(2026, 1, 1), amount: 1000, quantity: 100)],
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 1, 31),
      );
      expect(r['2026-01-01']!.$1, 100);
      expect(r['2026-01-01']!.$2, closeTo(1000, 1e-9));
      expect(r['2026-01-31']!.$1, 100);
      expect(r['2026-01-31']!.$2, closeTo(1000, 1e-9));
    });

    test('partial sell reduces quantity, unit cost unchanged', () {
      final h = _holding(quantity: 50, costPrice: 10);
      final r = replay.replay(
        h,
        [
          _txn(id: 1, type: 'buy', at: DateTime(2026, 1, 1), amount: 1000, quantity: 100),
          _txn(id: 2, type: 'sell', at: DateTime(2026, 2, 1), amount: 600, quantity: 50),
        ],
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 2, 28),
      );
      expect(r['2026-01-15']!.$1, 100);
      expect(r['2026-01-15']!.$2, closeTo(1000, 1e-9));
      expect(r['2026-02-01']!.$1, 50);
      expect(r['2026-02-01']!.$2, closeTo(500, 1e-9));
      expect(r['2026-02-28']!.$1, 50);
      expect(r['2026-02-28']!.$2, closeTo(500, 1e-9));
    });

    test('sold-out holding reconstructs its full history', () {
      final h = _holding(quantity: 0, costPrice: 0);
      final r = replay.replay(
        h,
        [
          _txn(id: 1, type: 'buy', at: DateTime(2026, 1, 1), amount: 1000, quantity: 100),
          _txn(id: 2, type: 'sell', at: DateTime(2026, 2, 1), amount: 1200, quantity: 100),
        ],
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 2, 28),
      );
      expect(r['2026-01-01']!.$1, 100);
      expect(r['2026-01-01']!.$2, closeTo(1000, 1e-9));
      expect(r['2026-01-31']!.$1, 100);
      // Sell day: position emptied.
      expect(r['2026-02-01']!.$1, 0);
      expect(r['2026-02-01']!.$2, 0);
      expect(r['2026-02-28']!.$1, 0);
    });

    test('dividend before a full sell-out is reconstructed exactly', () {
      // buy 100 @ 1000, dividend 50 (cost -> 950), sell 100 @ 1100.
      final h = _holding(quantity: 0, costPrice: 0);
      final r = replay.replay(
        h,
        [
          _txn(id: 1, type: 'buy', at: DateTime(2026, 1, 1), amount: 1000, quantity: 100),
          _txn(id: 2, type: 'dividend', at: DateTime(2026, 3, 1), amount: 50),
          _txn(id: 3, type: 'sell', at: DateTime(2026, 4, 1), amount: 1100, quantity: 100),
        ],
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 4, 30),
      );
      expect(r['2026-02-15']!.$2, closeTo(1000, 1e-9));
      // After the dividend the cost basis drops by 50.
      expect(r['2026-03-01']!.$2, closeTo(950, 1e-9));
      expect(r['2026-03-31']!.$2, closeTo(950, 1e-9));
      expect(r['2026-04-01']!.$1, 0);
      expect(r['2026-04-01']!.$2, 0);
    });

    test('split multiplies quantity and divides unit cost', () {
      // buy 100 @ 1000, 1:2 split (ratio 2) -> 200 @ 5.
      final h = _holding(quantity: 200, costPrice: 5);
      final r = replay.replay(
        h,
        [
          _txn(id: 1, type: 'buy', at: DateTime(2026, 1, 1), amount: 1000, quantity: 100),
          _txn(id: 2, type: 'split', at: DateTime(2026, 2, 1), amount: 2),
        ],
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 2, 28),
      );
      expect(r['2026-01-15']!.$1, 100);
      expect(r['2026-01-15']!.$2, closeTo(1000, 1e-9));
      expect(r['2026-02-01']!.$1, 200);
      expect(r['2026-02-01']!.$2, closeTo(1000, 1e-9));
    });

    test('buy-back after sell-out restarts the position', () {
      final h = _holding(quantity: 40, costPrice: 12.5);
      final r = replay.replay(
        h,
        [
          _txn(id: 1, type: 'buy', at: DateTime(2026, 1, 1), amount: 1000, quantity: 100),
          _txn(id: 2, type: 'sell', at: DateTime(2026, 2, 1), amount: 1200, quantity: 100),
          _txn(id: 3, type: 'buy', at: DateTime(2026, 3, 1), amount: 500, quantity: 40),
        ],
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 3, 31),
      );
      expect(r['2026-01-15']!.$1, 100);
      expect(r['2026-02-15']!.$1, 0);
      expect(r['2026-03-01']!.$1, 40);
      expect(r['2026-03-01']!.$2, closeTo(500, 1e-9));
    });

    test('initial position without any flow is kept constant', () {
      final h = _holding(quantity: 10, costPrice: 20);
      final r = replay.replay(
        h,
        const [],
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 1, 31),
      );
      expect(r['2026-01-01']!.$1, 10);
      expect(r['2026-01-01']!.$2, closeTo(200, 1e-9));
      expect(r['2026-01-31']!.$1, 10);
      expect(r['2026-01-31']!.$2, closeTo(200, 1e-9));
    });
  });

  group('ProductEarningsCalculator', () {
    test('monthly product attribution excludes gain carried in by a buy', () {
      final products = calc.compute([
        HoldingSeries(
          holdingId: 1,
          name: 'ETF',
          type: AssetType.etf,
          closed: false,
          days: const [
            HoldingDay(date: '2026-10-31', value: 1000, cost: 1000),
            HoldingDay(
              date: '2026-11-01',
              value: 5595,
              cost: 4800,
              profitAdjustment: -800,
            ),
          ],
        ),
        HoldingSeries(
          holdingId: 2,
          name: '现金',
          type: AssetType.cash,
          closed: false,
          days: const [
            HoldingDay(date: '2026-10-31', value: 10000, cost: 9000),
            HoldingDay(
              date: '2026-11-01',
              value: 5400,
              cost: 5200,
              profitAdjustment: 800,
            ),
          ],
        ),
      ]);
      final fund = products.firstWhere((p) => p.name == 'ETF');
      final cash = products.firstWhere((p) => p.name == '现金');
      expect(fund.daily.last.cost, 4800); // Preserve the recorded basis.
      expect(calc.monthOf(fund, 2026, 11).profit, closeTo(-5, 1e-9));
      expect(calc.monthOf(cash, 2026, 11).profit, closeTo(0, 1e-9));
      expect(calc.yearlyProfit(calc.yearOf(fund, 2026)), closeTo(-5, 1e-9));
    });

    test('same-name adjustments merge without creating a phantom position', () {
      HoldingSeries member(int id, double adjustment) => HoldingSeries(
        holdingId: id,
        name: '基金',
        type: AssetType.etf,
        closed: true,
        days: [
          const HoldingDay(date: '2026-10-31', value: 100, cost: 100),
          HoldingDay(
            date: '2026-11-01', value: 0, cost: 0,
            profitAdjustment: adjustment,
          ),
          const HoldingDay(date: '2026-11-02', value: 0, cost: 0),
        ],
      );
      final product = calc.compute([member(1, 4), member(2, 6)]).single;
      expect(product.holdingIds, [1, 2]);
      final month = calc.monthOf(product, 2026, 11);
      expect(month.dailyProfits, [10]);
      expect(month.closed, true);
      expect(product.daily.last.cost, 0);
    });

    test('first snapshot of new year uses prior snapshot and its correction', () {
      final product = calc.compute([
        HoldingSeries(
          holdingId: 1,
          name: 'ETF',
          type: AssetType.etf,
          closed: false,
          days: const [
            HoldingDay(date: '2025-12-30', value: 1000, cost: 1000),
            HoldingDay(
              date: '2026-01-02',
              value: 5595,
              cost: 4800,
              profitAdjustment: -800,
            ),
          ],
        ),
      ]).single;
      final month = calc.monthOf(product, 2026, 1);
      expect(month.days, 1);
      expect(month.profit, closeTo(-5, 1e-9));
      expect(calc.yearlyProfit(calc.yearOf(product, 2026)), closeTo(-5, 1e-9));
      expect(month.rate, closeTo(-5 / 5595, 1e-9));
    });

    test('monthly profit is the sum of daily value-cost deltas', () {
      // value rises 100 -> 110 over the month, cost constant 100.
      final p = ProductEarnings(
        name: '基金A',
        type: AssetType.mutualFund,
        closed: false,
        daily: [
          (date: '2026-01-31', value: 100, cost: 100),
          (date: '2026-02-01', value: 105, cost: 100),
          (date: '2026-02-15', value: 108, cost: 100),
          (date: '2026-02-28', value: 110, cost: 100),
        ],
      );
      final m = calc.monthOf(p, 2026, 2);
      expect(m.days, 3);
      expect(m.profit, closeTo(10, 1e-9));
      // Base = value on the month's first data day (2026-02-01).
      expect(m.rate, closeTo(10 / 105, 1e-9));
    });

    test('first month has a zero-profit first day (no baseline)', () {
      final p = ProductEarnings(
        name: '基金A',
        type: AssetType.mutualFund,
        closed: false,
        daily: [
          (date: '2026-01-01', value: 100, cost: 100),
          (date: '2026-01-31', value: 120, cost: 100),
        ],
      );
      final m = calc.monthOf(p, 2026, 1);
      expect(m.days, 2);
      expect(m.profit, closeTo(20, 1e-9));
    });

    test('months without data return zero days', () {
      final p = ProductEarnings(
        name: '基金A',
        type: AssetType.mutualFund,
        closed: false,
        daily: [
          (date: '2026-02-01', value: 100, cost: 100),
        ],
      );
      expect(calc.monthOf(p, 2026, 1).days, 0);
      expect(calc.monthOf(p, 2026, 3).days, 0);
    });

    test('sell-out month carries the realized gain and a closed flag', () {
      // Position 100 @ cost 100; marked 110 on the sell day, then empty.
      final p = ProductEarnings(
        name: '基金A',
        type: AssetType.mutualFund,
        closed: true,
        daily: [
          (date: '2026-01-31', value: 100, cost: 100),
          (date: '2026-02-01', value: 110, cost: 100),
        ],
      );
      final m = calc.monthOf(p, 2026, 2);
      // Δ(value-cost) = (110-100) - (100-100) = 10 realized gain.
      expect(m.profit, closeTo(10, 1e-9));
      expect(m.closed, true);
      expect(calc.monthOf(p, 2026, 1).closed, isNull);
    });

    test('holdings with the same name merge across accounts', () {
      final products = calc.compute([
        HoldingSeries(
          holdingId: 1,
          name: '基金A',
          type: AssetType.mutualFund,
          closed: false,
          days: [
            const HoldingDay(date: '2026-01-31', value: 100, cost: 100),
            const HoldingDay(date: '2026-02-01', value: 110, cost: 100),
          ],
        ),
        HoldingSeries(
          holdingId: 2,
          name: '基金A',
          type: AssetType.mutualFund,
          closed: false,
          days: [
            const HoldingDay(date: '2026-01-31', value: 50, cost: 50),
            const HoldingDay(date: '2026-02-01', value: 55, cost: 50),
          ],
        ),
        HoldingSeries(
          holdingId: 3,
          name: '基金B',
          type: AssetType.stock,
          closed: false,
          days: [
            const HoldingDay(date: '2026-01-31', value: 80, cost: 80),
            const HoldingDay(date: '2026-02-01', value: 78, cost: 80),
          ],
        ),
      ]);
      expect(products.length, 2);
      final a = products.firstWhere((p) => p.name == '基金A');
      expect(a.daily.length, 2);
      expect(a.daily[0].value, 150);
      expect(a.daily[0].cost, 150);
      expect(a.daily[1].value, 165);
      final m = calc.monthOf(a, 2026, 2);
      expect(m.profit, closeTo(15, 1e-9));
      // Base = merged value on the month's first data day (2026-02-01).
      expect(m.rate, closeTo(15 / 165, 1e-9));
    });

    test('product is closed only when all its holdings are sold out', () {
      final products = calc.compute([
        HoldingSeries(
          holdingId: 1,
          name: '基金A',
          type: AssetType.mutualFund,
          closed: true,
          days: [const HoldingDay(date: '2026-02-01', value: 0, cost: 0)],
        ),
        HoldingSeries(
          holdingId: 2,
          name: '基金A',
          type: AssetType.mutualFund,
          closed: false,
          days: [const HoldingDay(date: '2026-02-01', value: 10, cost: 10)],
        ),
      ]);
      expect(products.single.closed, false);
    });

    test('yearly aggregates sum the months', () {
      final p = ProductEarnings(
        name: '基金A',
        type: AssetType.mutualFund,
        closed: false,
        daily: [
          (date: '2026-01-31', value: 100, cost: 100),
          (date: '2026-02-01', value: 110, cost: 100),
          (date: '2026-02-28', value: 105, cost: 100),
          (date: '2026-03-01', value: 120, cost: 100),
        ],
      );
      final months = calc.yearOf(p, 2026);
      expect(months.length, 3);
      // Jan: 2026-01-31 is the first data day -> no baseline, profit 0.
      // Feb: (110-100)-(100-100) + (105-100)-(110-100) = 10 - 5 = 5.
      // Mar: (120-100)-(105-100) = 15.
      expect(calc.yearlyProfit(months), closeTo(20, 1e-9));
      expect(calc.yearlyRate(months, p, 2026), closeTo(20 / 100, 1e-9));
    });
  });
}
