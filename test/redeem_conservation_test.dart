import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/domain/trade_stats.dart';
import 'package:asset_tracker/domain/transaction_service.dart';

/// Regression tests for the 2026-09-24「月月宝 → 五年国债ETF」report:
/// recording a buy funded by redeeming another holding inflated the total
/// cost by the redeemed lot's unrealized gain, so the same-day P/L showed a
/// phantom loss of exactly that gain — and the realized-profit estimates
/// counted the internal redemption as a realization on top of the gain
/// being carried into the new holding (double count).
///
/// Fixed by making the redemption-funded flows conserve total cost (the
/// target's cost basis = the principal that left the source, never the
/// market amount) and by marking the internal legs so they are excluded
/// from the realized-profit estimates.
void main() {
  late AppDatabase db;
  late AssetDao dao;
  late TransactionService service;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
    service = TransactionService(dao);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> addAccount(String name) =>
      dao.createAccount(AccountsCompanion.insert(name: name, type: 'general'));

  Future<int> addHolding({
    required int accountId,
    required String name,
    required AssetType type,
    double quantity = 0,
    double costPrice = 0,
    double latestPrice = 0,
  }) {
    return dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: name,
      assetType: type.storageName,
      marketSource: Value(type.isMarketLinked ? 'sina' : 'manual'),
      quantity: Value(quantity),
      costPrice: Value(costPrice),
      latestPrice: Value(latestPrice),
      currency: const Value('CNY'),
    ));
  }

  Future<HoldingRow> holding(int id) async =>
      (await dao.getHoldings()).firstWhere((h) => h.id == id);

  Future<double> totalCost() async {
    var total = 0.0;
    for (final h in await dao.getHoldings()) {
      final type = AssetType.fromStorage(h.assetType);
      if (type == AssetType.liability) continue;
      total += type.isAmountBased
          ? (h.costPrice > 0 ? h.costPrice : h.quantity)
          : h.quantity * h.costPrice;
    }
    return total;
  }

  Future<double> totalProfit() async {
    final s = const PortfolioCalculator().compute(
      await dao.getHoldings(),
      sellTransactions: await dao.getTransactions(),
    );
    return s.profit;
  }

  group('赎回出资买入：总成本守恒（今日收益不被换仓扭曲）', () {
    test('份额型来源：目标成本 = 赎回份额的本金，而不是市场金额', () async {
      final acc = await addAccount('A');
      final mmf = await addHolding(
        accountId: acc, name: '月月宝', type: AssetType.mutualFund,
        quantity: 1000, costPrice: 1, latestPrice: 2,
      );
      final fund = await addHolding(
        accountId: acc, name: '国债ETF', type: AssetType.etf,
        quantity: 0, costPrice: 0, latestPrice: 10,
      );
      final costBefore = await totalCost();
      final profitBefore = await totalProfit();

      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: mmf, targetHoldingId: fund,
        targetQuantity: 100, targetPrice: 10, amount: 1000,
      );
      expect(r.ok, isTrue);

      // 500 units left, carrying 500 x 1 = 500 of principal — the target
      // must NOT book the full market 1000 (that re-books a 500 gain as
      // fresh principal → total cost +500 → same-day loss of -500).
      expect((await holding(mmf)).quantity, closeTo(500, 1e-6));
      expect((await holding(fund)).costPrice, closeTo(5, 1e-9));
      expect(await totalCost(), closeTo(costBefore, 1e-6),
          reason: '资金在产品间搬运，组合总成本分毫不动');
      expect(await totalProfit(), closeTo(profitBefore, 1e-6),
          reason: '未实现收益也分毫不动（市值同步平移）');
    });

    test('金额型来源有未实现收益：目标成本 = 按比例移动的本金', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '余额宝', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 3000, latestPrice: 1, // gain 2000
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 10,
      );
      final costBefore = await totalCost();
      final profitBefore = await totalProfit();

      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: cash, targetHoldingId: fund,
        targetQuantity: 100, targetPrice: 10, amount: 1000,
      );
      expect(r.ok, isTrue);

      // Proportional principal: 3000 x 1000/5000 = 600 travelled. The
      // target cost basis is 600 (a 1000-amount here would re-book 400 of
      // the balance's gain as new principal).
      final cashAfter = await holding(cash);
      expect(cashAfter.quantity, closeTo(4000, 1e-6));
      expect(cashAfter.costPrice, closeTo(2400, 1e-6));
      expect((await holding(fund)).costPrice, closeTo(6, 1e-9));
      expect(await totalCost(), closeTo(costBefore, 1e-6));
      expect(await totalProfit(), closeTo(profitBefore, 1e-6));
    });
  });

  group('内部赎回不入已实现收益', () {
    test('PortfolioCalculator.realizedProfit 跳过内部赎回腿', () async {
      final acc = await addAccount('A');
      final stock = await addHolding(
        accountId: acc, name: '股票', type: AssetType.stock,
        quantity: 100, costPrice: 10, latestPrice: 20,
      );
      // A real sell (proceeds parked in cash): realizes (15 - 10) x 40.
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 600, costPrice: 600, latestPrice: 1,
      );
      await service.record(
        accountId: acc, holdingId: stock, type: TransactionType.sell,
        quantity: 40, price: 15, amount: 600, cashTargetId: cash,
      );
      // An internal redemption (proceeds fund another holding): 30 shares
      // at cost 10, value 20 -> 15 shares remain; the cost of the redeemed
      // units travels into the new position, nothing is realized.
      final fund = await addHolding(
        accountId: acc, name: '新基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      await service.recordBuyFundedByHolding(
        sourceHoldingId: stock, targetHoldingId: fund,
        targetQuantity: 60, targetPrice: 10, amount: 600,
      );

      final s = const PortfolioCalculator().compute(
        await dao.getHoldings(),
        sellTransactions: await dao.getTransactions(),
      );
      // Only the real sell counts: (15 - 10) x 40 = 200. The internal
      // redemption's (20 - 10) x 30 = 300 must NOT be added on top of the
      // 300 the new position already carries in its cost basis.
      expect(s.realizedProfit, closeTo(200, 1e-6));
    });

    test('TradeStats.realizedProfit / realizedProfitByHolding 同样跳过', () async {
      final acc = await addAccount('A');
      final stock = await addHolding(
        accountId: acc, name: '股票', type: AssetType.stock,
        quantity: 100, costPrice: 10, latestPrice: 20,
      );
      final fund = await addHolding(
        accountId: acc, name: '新基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      await service.recordBuyFundedByHolding(
        sourceHoldingId: stock, targetHoldingId: fund,
        targetQuantity: 60, targetPrice: 10, amount: 600,
      );

      final txns = await dao.getTransactions();
      final costByHolding = {for (final h in await dao.getHoldings()) h.id: h.costPrice};
      final stats = const TradeStatsCalculator().compute(txns, await dao.getHoldings());
      expect(stats.realizedProfit, closeTo(0, 1e-6));
      final byHolding = TradeStatsCalculator.realizedProfitByHolding(
        txns,
        costByHolding,
        amountBasedHoldingIds: const {},
      );
      expect(byHolding, isEmpty);
    });
  });

  group('整笔撤销回滚干净', () {
    test('删除内部赎买的买卖两条腿后，余额与成本全部还原', () async {
      final acc = await addAccount('A');
      final mmf = await addHolding(
        accountId: acc, name: '月月宝', type: AssetType.mutualFund,
        quantity: 1000, costPrice: 1, latestPrice: 2,
      );
      final fund = await addHolding(
        accountId: acc, name: '国债ETF', type: AssetType.etf,
        quantity: 0, costPrice: 0, latestPrice: 10,
      );
      final costBefore = await totalCost();

      await service.recordBuyFundedByHolding(
        sourceHoldingId: mmf, targetHoldingId: fund,
        targetQuantity: 100, targetPrice: 10, amount: 1000,
      );
      final rows = await dao.getTransactions();
      final sell = rows.firstWhere((t) => t.type == 'sell');
      final buy = rows.firstWhere((t) => t.type == 'buy');

      expect((await service.remove(sell.id)).ok, isTrue);
      final mmfAfterSell = await holding(mmf);
      expect(mmfAfterSell.quantity, closeTo(1000, 1e-6));
      expect(mmfAfterSell.costPrice, closeTo(1, 1e-9));

      expect((await service.remove(buy.id)).ok, isTrue);
      final fundAfterBuy = await holding(fund);
      expect(fundAfterBuy.quantity, closeTo(0, 1e-6));
      expect((await holding(mmf)).costPrice, closeTo(1, 1e-9));
      expect(await totalCost(), closeTo(costBefore, 1e-6));
    });
  });
}