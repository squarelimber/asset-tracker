import 'package:asset_tracker/core/market_session.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/portfolio_intraday.dart';
import 'package:asset_tracker/services/market/kline_source.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('默认分时覆盖 A 股交易与午休，收盘及休市回到长期趋势', () {
    bool showsTrend(DateTime instant) =>
        aShareSession(chinaMarketTime(instant)).showsIntradayTrend;
    expect(showsTrend(DateTime.utc(2026, 11, 18, 1, 29)), isFalse);
    expect(showsTrend(DateTime.utc(2026, 11, 18, 1, 30)), isTrue);
    expect(showsTrend(DateTime.utc(2026, 11, 18, 4)), isTrue);
    expect(showsTrend(DateTime.utc(2026, 11, 18, 7)), isFalse);
    expect(showsTrend(DateTime.utc(2026, 11, 21, 2)), isFalse);
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

  test('首次打开可用行情补齐早盘、盘中买入与清仓后的收益', () {
    const day = '2026-11-18';
    final now = DateTime.utc(2026, 11, 18, 6);
    final etf = HoldingRow(
      id: 1,
      accountId: 1,
      name: '有色 ETF',
      assetType: 'etf',
      marketSource: 'sina',
      symbol: 'sz159980',
      quantity: 0,
      costPrice: 2,
      latestPrice: 1.998,
      currency: 'CNY',
      archived: true,
      costRecorded: true,
      createdAt: now,
      updatedAt: now,
    );
    final trades = [
      TransactionRow(
        id: 1,
        accountId: 1,
        holdingId: etf.id,
        type: 'buy',
        quantity: 2300,
        amount: 4602.3,
        currency: 'CNY',
        cashSourceId: 9,
        occurredAt: DateTime.utc(2026, 11, 18, 2, 1, 35),
        costMoved: true,
        internalMove: false,
        updatedAt: now,
      ),
      TransactionRow(
        id: 2,
        accountId: 1,
        holdingId: etf.id,
        type: 'sell',
        quantity: 2400,
        amount: 4800,
        currency: 'CNY',
        cashTargetId: 9,
        occurredAt: DateTime.utc(2026, 11, 18, 3),
        costMoved: true,
        internalMove: true,
        updatedAt: now,
      ),
    ];
    const MarketIntraday series = (
      date: day,
      previousClose: 1.96,
      points: [
        (minute: 570, value: 1.999),
        (minute: 600, value: 2.0),
        (minute: 601, value: 1.998),
        (minute: 690, value: 1.987),
        (minute: 720, value: 1.98),
        (minute: 780, value: 1.99),
        (minute: 900, value: 2.02),
      ],
    );
    final history = rebuildPortfolioIntraday(
      day: day,
      now: now,
      priceHoldings: intradayPriceHoldings([
        etf,
        etf.copyWith(id: 2, symbol: const Value('sz159915'), quantity: 100),
        etf.copyWith(id: 9, assetType: 'savings', quantity: 8000),
      ], trades),
      transactions: trades,
      quotes: {
        'sz159980': series,
        'sz159915': (
          date: '2026-11-17',
          previousClose: series.previousClose,
          points: series.points,
        ),
      },
      rates: {},
    );
    expect(history.covered, 1);
    expect(history.eligible, 2);
    expect(history.points.map((p) => p.minute), [570, 600, 601, 690, 780]);
    expect(history.points.map((p) => p.profit), [
      closeTo(3.9, 1e-8),
      closeTo(4, 1e-8),
      closeTo(-3.1, 1e-8),
      closeTo(1.7, 1e-8),
      closeTo(1.7, 1e-8),
    ]);
  });
}
