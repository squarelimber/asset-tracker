import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/portfolio_intraday.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('默认分时覆盖 A 股交易与午休，收盘及休市回到长期趋势', () {
    expect(prefersTodayTrend(DateTime.utc(2026, 11, 18, 1, 29)), isFalse);
    expect(prefersTodayTrend(DateTime.utc(2026, 11, 18, 1, 30)), isTrue);
    expect(prefersTodayTrend(DateTime.utc(2026, 11, 18, 4)), isTrue);
    expect(prefersTodayTrend(DateTime.utc(2026, 11, 18, 7)), isFalse);
    expect(prefersTodayTrend(DateTime.utc(2026, 11, 21, 2)), isFalse);
  });

  test('买入、还款和充值不形成收益，成交后的跌幅仍保留', () {
    final now = DateTime(2026, 11, 18, 14);
    HoldingRow holding(int id, String type, double qty, [double price = 1]) =>
        HoldingRow(
          id: id,
          accountId: 1,
          name: type,
          assetType: type,
          marketSource: 'manual',
          quantity: qty,
          costPrice: 1,
          latestPrice: price,
          currency: 'CNY',
          archived: false,
          costRecorded: true,
          createdAt: now,
          updatedAt: now,
        );
    TransactionRow flow(
      int id,
      String type,
      double amount, {
      int? from,
      int? to,
    }) => TransactionRow(
      id: id,
      accountId: 1,
      type: type,
      amount: amount,
      currency: 'CNY',
      cashSourceId: from,
      cashTargetId: to,
      costMoved: true,
      internalMove: false,
      occurredAt: now,
      updatedAt: now,
    );
    final baseline = SnapshotRow(
      date: '2026-11-17',
      currency: 'CNY',
      totalValue: 9000,
      totalCost: 10000,
      liabilities: 1000,
      createdAt: now,
    );
    expect(
      intradayPortfolioProfit(
        baseline: baseline,
        holdings: [
          holding(1, 'savings', 7900),
          holding(2, 'liability', 500),
          holding(3, 'etf', 2300, 1.998),
        ],
        transactions: [
          flow(1, 'buy', 4602.3, from: 1),
          flow(2, 'transfer_in', 500, from: 1, to: 2),
          flow(3, 'income', 3002.3, to: 1),
        ],
        rates: {},
        now: now,
      ),
      closeTo(-6.9, 1e-8),
    );
  });
}
