import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/smooth_history.dart';

HoldingRow _amountHolding({
  double quantity = 1000,
  double cost = 1000,
}) {
  return HoldingRow(costRecorded: false, 
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
    archived: false,
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
    internalMove: false,
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
      today: DateTime(2026, 1, 11),
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
      today: DateTime(2026, 1, 11),
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

  test('future income flow does not leak into past-day windows', () {
    // Tiantianbao-style: inception 1/1 with 1,000,000 invested, then a
    // 122,544.9 income on 8/31. Both quantity and cost include the income
    // (gain = 0), so the all-time gain is 0.
    final h = _amountHolding(quantity: 1122544.9, cost: 1122544.9);
    final flows = [
      _income(id: 1, at: DateTime(2026, 8, 31), amount: 122544.9, targetId: 1),
    ];
    // Inspect a past day (1/15) that is well before the 8/31 income, with
    // "today" after the income. The 122,544.9 must NOT appear in the window.
    final map = calc.amountHistory(
      h,
      flows,
      from: DateTime(2026, 1, 1),
      to: DateTime(2026, 1, 15),
      today: DateTime(2026, 9, 6),
    );
    // Principal before the income is 1,000,000; with zero gain the value
    // stays flat at the pre-income principal.
    expect(map['2026-01-01'], closeTo(1000000, 1.0));
    expect(map['2026-01-15'], closeTo(1000000, 1.0));
    // Daily change is ~0, not the phantom 122,544.9.
    final dayChange = map['2026-01-15']! - map['2026-01-14']!;
    expect(dayChange.abs(), lessThan(1.0));
    // The income day itself still jumps by the full amount.
    final atIncome = calc.amountHistory(
      h,
      flows,
      from: DateTime(2026, 1, 1),
      to: DateTime(2026, 9, 6),
      today: DateTime(2026, 9, 6),
    );
    expect(atIncome['2026-08-31']! - atIncome['2026-08-30']!,
        closeTo(122544.9, 500));
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
    internalMove: false,
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
    final h = HoldingRow(costRecorded: false, 
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
      archived: false,
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
    internalMove: false,
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
    internalMove: false,
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

  test('a flow that empties the holding does not leave its principal behind',
      () {
    // 余额宝 on 2026-09-18: the whole balance was moved to the cash account,
    // so quantity and costPrice are both 0 now. Replaying the flow backwards
    // recovers the pre-transfer principal, which is right for the days before
    // it — but the transfer day itself must report 0. Leaving the pre-transfer
    // principal there inflated that one day's cost by the entire transfer
    // (117,327.38) while the day's value was already 0, which is the
    // "today's earning is -114,713.84" report.
    final h = _amountHolding(quantity: 0, cost: 0);
    final out = TransactionRow(
      id: 6,
      accountId: 1,
      holdingId: null,
      cashSourceId: 1,
      cashTargetId: 2,
      type: 'transfer_out',
      quantity: null,
      price: null,
      amount: 117327.38,
      currency: 'CNY',
      occurredAt: DateTime(2026, 9, 18, 10, 16, 8),
      note: null,
      costMoved: true,
    internalMove: false,
      updatedAt: DateTime(2026, 9, 18, 10, 16, 8),
    );
    final from = DateTime(2026, 9, 10);
    final to = DateTime(2026, 9, 18);

    final principal = calc.amountPrincipal(h, [out], from: from, to: to);
    expect(principal['2026-09-17'], closeTo(117327.38, 1e-6));
    expect(principal['2026-09-18'], closeTo(0, 1e-6),
        reason: 'the transfer day must report the post-transfer principal');

    final values = calc.amountHistory(h, [out], from: from, to: to, today: to);
    expect(values['2026-09-18'], closeTo(0, 1e-6));
    // Value and invested amount fall together, so the transfer day is not
    // charged a loss. This is the assertion the old code failed: it reported
    // a value drop of 117,327.38 against no cost drop at all.
    expect(
      values['2026-09-18']! - values['2026-09-17']!,
      closeTo(principal['2026-09-18']! - principal['2026-09-17']!, 1e-6),
    );
  });

  test('卖出回款进现金：本金按被卖份额成本而非全额（浮盈不记成本）', () {
    // A legacy sell row (written before costMovedAmount existed) parks the
    // full proceeds in the cash account. The cash principal must grow by the
    // *sold principal* (qty x unit cost), not the full proceeds — otherwise
    // the sell's unrealized gain is re-booked as cash cost and the rebuild
    // shows a phantom loss of that size on the sell day.
    final h = _amountHolding(quantity: 10000, cost: 10000);
    final sell = TransactionRow(
      id: 9,
      accountId: 1,
      holdingId: 5,
      cashSourceId: null,
      cashTargetId: 1,
      type: 'sell',
      quantity: 1000,
      price: 1.8,
      amount: 1800, // proceeds = 1000 x 1.8
      currency: 'CNY',
      occurredAt: DateTime(2026, 1, 5),
      note: null,
      costMoved: true,
      internalMove: false,
      updatedAt: DateTime(2026, 1, 5),
    );
    final from = DateTime(2026, 1, 1);
    final to = DateTime(2026, 1, 11);

    // Without the replay-captured sold principal, the legacy row falls back
    // to the full amount (backward compatible with pre-fix data).
    final legacy = calc.amountPrincipal(h, [sell], from: from, to: to);
    expect(legacy['2026-01-04'], closeTo(8200, 1e-6),
        reason: 'current cost 10000 minus full proceeds 1800');
    expect(legacy['2026-01-05'], closeTo(10000, 1e-6),
        reason: 'legacy rows without costMovedAmount keep the full-amount '
            'behaviour (they stay as recorded)');

    // With the sold principal (qty x unit cost = 1000 x 1.0 = 1000) supplied
    // by the replay, only that principal enters the cash cost.
    final fixed = calc.amountPrincipal(h, [sell],
        from: from, to: to, soldPrincipalById: {9: 1000});
    expect(fixed['2026-01-04'], closeTo(9000, 1e-6),
        reason: 'pre-sell principal = 10000 - sold principal 1000');
    expect(fixed['2026-01-05'], closeTo(10000, 1e-6),
        reason: 'the sold principal (1000), not the proceeds (1800), credits '
            'the cash cost — the 800 gain stays unrealized on the cash side');
  });

  test('卖出回款腿优先用 costMovedAmount（新流水直接记录份额成本）', () {
    final h = _amountHolding(quantity: 10000, cost: 10000);
    final sell = TransactionRow(
      id: 10,
      accountId: 1,
      holdingId: 5,
      cashSourceId: null,
      cashTargetId: 1,
      type: 'sell',
      quantity: 1000,
      price: 1.8,
      amount: 1800,
      currency: 'CNY',
      occurredAt: DateTime(2026, 1, 5),
      note: null,
      costMoved: true,
      internalMove: false,
      costMovedAmount: 1000, // recorded at write time
      updatedAt: DateTime(2026, 1, 5),
    );

    final map = calc.amountPrincipal(h, [sell],
        from: DateTime(2026, 1, 1), to: DateTime(2026, 1, 11));
    expect(map['2026-01-04'], closeTo(9000, 1e-6),
        reason: 'pre-sell principal = 10000 - recorded sold principal 1000');
    expect(map['2026-01-05'], closeTo(10000, 1e-6),
        reason: 'costMovedAmount (the recorded sold principal) wins over '
            'the raw amount');
  });

  group('负 principal 段（旧流水大额支出超过当时本金）', () {
    // 账户当前余额与成本一致（gain=0），简化验证；历史某笔 expense
    // 的原始金额（无 costMovedAmount 回退）大于当时本金 → 产生负段。
    TransactionRow expenseOf(int id, DateTime at, double amount) =>
        TransactionRow(
          id: id,
          accountId: 1,
          holdingId: null,
          cashSourceId: null,
          cashTargetId: 1,
          type: 'expense',
          quantity: null,
          price: null,
          amount: amount,
          currency: 'CNY',
          occurredAt: at,
          note: null,
          costMoved: true,
          internalMove: false,
          costMovedAmount: null, // 旧流水缺省 → 回退原始 amount
          updatedAt: at,
        );

    test('H2: 负段不计入收益权重，正段分配总量恒等于 totalGain', () {
      final h = _amountHolding(quantity: 1000, cost: 1000); // gain 0
      // 1/5 -1200（本金 500 被超扣 → 负段 -700），1/8 内部返还 +2200。
      final flows = [
        expenseOf(1, DateTime(2026, 1, 5), 1200),
        _income(id: 2, at: DateTime(2026, 1, 8), amount: 2200, targetId: 1),
      ];
      final map = calc.amountHistory(
        h,
        flows,
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 1, 11),
        today: DateTime(2026, 1, 11),
      );
      // 负段（1/5~1/7）值侧屏蔽为 0（empty 语义）。
      expect(map['2026-01-06'], 0, reason: '负本金段值侧为 0');
      // 末日钉到真实余额。
      expect(map['2026-01-11'], closeTo(1000, 1e-6));
      // gain=0：任何一天都不得因为权重污染出现假盈亏。
      for (final e in map.entries) {
        expect(e.value, greaterThanOrEqualTo(-1e-6),
            reason: 'gain=0 时负段权重不得让正段超分配出假负值');
      }
    });

    test('H3: 负段成本输出 0，不产生负 cost 幻象', () {
      final h = _amountHolding(quantity: 1000, cost: 1000);
      final flows = [
        expenseOf(1, DateTime(2026, 1, 5), 1200),
        _income(id: 2, at: DateTime(2026, 1, 8), amount: 2200, targetId: 1),
      ];
      final map = calc.amountPrincipal(
        h,
        flows,
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 1, 11),
      );
      // 负段日子成本为 0（与值侧一致，禁止负 totalCost）。
      expect(map['2026-01-06'], 0, reason: '负本金段成本侧为 0');
      expect(map['2026-01-10'], closeTo(1000, 1e-6),
          reason: '恢复正常段后成本回到正的本金');
    });
  });
}
