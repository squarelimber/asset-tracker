import 'dart:math';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/daily_earnings.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/domain/smooth_history.dart';
import 'package:asset_tracker/domain/transaction_service.dart';

/// Hard invariants for **account-to-account money moves**: a transfer (or
/// any internal movement — sell parked in cash, buy funded from cash,
/// redeem-to-buy) must never:
///   1. change the portfolio's total market value (no phantom gain/loss),
///   2. change the portfolio's total cost (no invented/destroyed principal)
///      — and therefore never move `profit = value - cost`, which is the
///      exact number the daily earnings (今日盈亏/收益日历) are built from,
///   3. change the replayed principal timeline (a history rebuild after the
///      move must agree with the one before it, day for day).
/// Deleting the row must restore all three exactly.
///
/// These tests are the standing guarantee behind the 2026-09-24 reports
/// (转账/赎回买新/卖出回款到现金「资产算错」): if any future change breaks
/// conservation, the whole suite goes red.
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

  Future<int> addAmountBased(
    int accountId, {
    required String name,
    required double balance,
    required double invested,
    AssetType type = AssetType.bankDeposit,
  }) {
    return dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: name,
      assetType: type.storageName,
      marketSource: const Value('manual'),
      quantity: Value(balance),
      costPrice: Value(invested),
      latestPrice: const Value(1),
      purchaseDate: Value(DateTime(2026, 1, 1)),
    ));
  }

  Future<int> addShareBased(
    int accountId, {
    required String name,
    required AssetType type,
    required double quantity,
    required double costPrice,
    required double latestPrice,
  }) {
    return dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: name,
      assetType: type.storageName,
      marketSource: Value(type.isMarketLinked ? 'sina' : 'manual'),
      quantity: Value(quantity),
      costPrice: Value(costPrice),
      latestPrice: Value(latestPrice),
      purchaseDate: Value(DateTime(2026, 1, 1)),
    ));
  }

  Future<HoldingRow> holding(int id) async =>
      (await dao.getHoldings()).firstWhere((h) => h.id == id);

  /// Market value of every non-liability holding, CNY (flat rates).
  Future<double> liveValue() async {
    var total = 0.0;
    for (final h in await dao.getHoldings()) {
      final type = AssetType.fromStorage(h.assetType);
      if (type == AssetType.liability) continue;
      total += type.isAmountBased ? h.quantity : h.quantity * h.latestPrice;
    }
    return total;
  }

  /// Total cost basis, same convention as [PortfolioCalculator].
  Future<double> liveCost() async {
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

  /// Snapshot-style profit: the number 今日盈亏/收益日历 are built from.
  Future<double> liveProfit() async => (await liveValue()) - (await liveCost());

  /// Records [tx] and asserts the "internal move" invariants hold.
  /// Returns the created row ids.
  Future<List<int>> recordAndAssertInternal({
    required int accountId,
    int? holdingId,
    required TransactionType type,
    double? quantity,
    double? price,
    required double amount,
    int? cashSourceId,
    int? cashTargetId,
  }) async {
    final valueBefore = await liveValue();
    final costBefore = await liveCost();
    final profitBefore = await liveProfit();
    final r = await service.record(
      accountId: accountId,
      holdingId: holdingId,
      type: type,
      quantity: quantity,
      price: price,
      amount: amount,
      cashSourceId: cashSourceId,
      cashTargetId: cashTargetId,
    );
    expect(r.ok, isTrue);
    expect(await liveValue(), closeTo(valueBefore, 1e-6),
        reason: '内部资金搬运不得改变总市值（无凭空增值/减值）');
    expect(await liveCost(), closeTo(costBefore, 1e-6),
        reason: '内部资金搬运不得改变总成本（无凭空造/灭本金）');
    expect(await liveProfit(), closeTo(profitBefore, 1e-6),
        reason: '内部资金搬运不得改变收益（今日盈亏/收益日历的口径）');
    return (await dao.getTransactions())
        .where((t) => t.amount == amount)
        .map((t) => t.id)
        .toList();
  }

  group('转账（金额型账户之间）', () {
    test('带浮盈的账户转出：市值/成本/收益分毫不动，删除后完全还原', () async {
      final acc = await addAccount('A');
      final a = await addAmountBased(acc, name: '余额宝', balance: 10000, invested: 8000);
      final b = await addAmountBased(acc, name: '现金账户', balance: 0, invested: 0);
      final v0 = await liveValue();
      final c0 = await liveCost();
      final p0 = await liveProfit();

      final ids = await recordAndAssertInternal(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 6000,
        cashSourceId: a,
        cashTargetId: b,
      );
      // Source keeps its gain rate: 8000 - (8000 x 6000/10000) = 3200;
      // target receives the same moved principal 4800.
      expect((await holding(a)).costPrice, closeTo(3200, 1e-6));
      expect((await holding(b)).costPrice, closeTo(4800, 1e-6));

      final row = (await dao.getTransactions()).single;
      expect(row.costMovedAmount, closeTo(4800, 1e-6));

      expect((await service.remove(ids.single)).ok, isTrue);
      expect(await liveValue(), closeTo(v0, 1e-6));
      expect(await liveCost(), closeTo(c0, 1e-6));
      expect(await liveProfit(), closeTo(p0, 1e-6));
      expect((await holding(a)).costPrice, closeTo(8000, 1e-6));
      expect((await holding(b)).quantity, closeTo(0, 1e-6));
    });

    test('全额转出（清空账户）：本金全部离开，不留下歧义', () async {
      final acc = await addAccount('A');
      final a = await addAmountBased(acc, name: '余额宝', balance: 10000, invested: 8000);
      final b = await addAmountBased(acc, name: '现金账户', balance: 0, invested: 0);

      await recordAndAssertInternal(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 10000,
        cashSourceId: a,
        cashTargetId: b,
      );
      expect((await holding(a)).quantity, closeTo(0, 1e-6));
      expect((await holding(a)).costPrice, closeTo(0, 1e-6));
      expect((await holding(b)).costPrice, closeTo(8000, 1e-6));
    });
  });

  group('卖出回款到现金 / 从现金买入（0.9.23 修复）', () {
    test('卖出回款：现金本金只加被卖份额成本，三不变量保持', () async {
      final acc = await addAccount('A');
      final fund = await addShareBased(acc,
          name: '基金', type: AssetType.mutualFund,
          quantity: 1000, costPrice: 1, latestPrice: 2);
      final cash = await addAmountBased(acc, name: '现金账户', balance: 0, invested: 0);

      final ids = await recordAndAssertInternal(
        accountId: acc,
        holdingId: fund,
        type: TransactionType.sell,
        quantity: 500,
        price: 2,
        amount: 1000,
        cashTargetId: cash,
      );
      expect((await holding(cash)).quantity, closeTo(1000, 1e-6));
      expect((await holding(cash)).costPrice, closeTo(500, 1e-6));
      expect((await service.remove(ids.single)).ok, isTrue);
      expect((await holding(fund)).quantity, closeTo(1000, 1e-6));
      expect((await holding(cash)).quantity, closeTo(0, 1e-6));
    });

    test('从带浮盈的现金买入：目标成本=移动本金，三不变量保持', () async {
      final acc = await addAccount('A');
      final cash = await addAmountBased(acc, name: '余额宝', balance: 5000, invested: 3000);
      final fund = await addShareBased(acc,
          name: '基金', type: AssetType.mutualFund,
          quantity: 0, costPrice: 0, latestPrice: 10);

      final ids = await recordAndAssertInternal(
        accountId: acc,
        holdingId: fund,
        type: TransactionType.buy,
        quantity: 100,
        price: 10,
        amount: 1000,
        cashSourceId: cash,
      );
      expect((await holding(cash)).costPrice, closeTo(2400, 1e-6));
      expect((await holding(fund)).costPrice, closeTo(6, 1e-9));
      expect((await service.remove(ids.single)).ok, isTrue);
      expect((await holding(cash)).quantity, closeTo(5000, 1e-6));
      expect((await holding(fund)).quantity, closeTo(0, 1e-6));
    });
  });

  group('赎回买新（0.9.21 修复）', () {
    test('份额型来源：三不变量保持，删除两腿完全还原', () async {
      final acc = await addAccount('A');
      final mmf = await addShareBased(acc,
          name: '月月宝', type: AssetType.bankWealth,
          quantity: 1000, costPrice: 1, latestPrice: 2);
      final fund = await addShareBased(acc,
          name: '国债ETF', type: AssetType.etf,
          quantity: 0, costPrice: 0, latestPrice: 10);
      final v0 = await liveValue();
      final c0 = await liveCost();
      final p0 = await liveProfit();

      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: mmf,
        targetHoldingId: fund,
        targetQuantity: 100,
        targetPrice: 10,
        amount: 1000,
      );
      expect(r.ok, isTrue);
      expect(await liveValue(), closeTo(v0, 1e-6));
      expect(await liveCost(), closeTo(c0, 1e-6));
      expect(await liveProfit(), closeTo(p0, 1e-6));
      expect((await holding(fund)).costPrice, closeTo(5, 1e-9));

      final sell = (await dao.getTransactions())
          .firstWhere((t) => t.type == TransactionType.sell.storageName);
      final buy = (await dao.getTransactions())
          .firstWhere((t) => t.type == TransactionType.buy.storageName);
      expect((await service.remove(sell.id)).ok, isTrue);
      expect((await service.remove(buy.id)).ok, isTrue);
      expect(await liveValue(), closeTo(v0, 1e-6));
      expect(await liveCost(), closeTo(c0, 1e-6));
      expect(await liveProfit(), closeTo(p0, 1e-6));
    });
  });

  group('历史重放与转账一致（重建历史快照不因转账漂移）', () {
    test('有 costMovedAmount 的行：重放的每日本金与写入侧逐日一致', () async {
      final acc = await addAccount('A');
      final a = await addAmountBased(acc, name: '余额宝', balance: 10000, invested: 8000);
      final b = await addAmountBased(acc, name: '现金账户', balance: 0, invested: 0);
      final day = DateTime(2026, 6, 1, 10, 30);
      await service.record(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 6000,
        cashSourceId: a,
        cashTargetId: b,
        occurredAt: day,
      );

      final calc = const SmoothHistoryCalculator();
      final flowsTarget = await dao.getTransactionsForHolding(b);
      final target = await holding(b);
      final principal = calc.amountPrincipal(
        target,
        flowsTarget,
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 9, 1),
      );
      // 转账日（重放把当日归入新段）：目标本金 = 写入侧实际移动的 4800，
      // 不是原始金额 6000 —— 旧口径会偏移账户浮盈 2000*。
      expect(principal['2026-06-01'], closeTo(4800, 1e-6));
      expect(principal['2026-05-31'], closeTo(0, 1e-6)); // 转账前目标为空
    });

    test('快照口径：转账当日 今日盈亏/收益 = 0（平盘）', () async {
      final acc = await addAccount('A');
      final a = await addAmountBased(acc, name: '余额宝', balance: 10000, invested: 8000);
      final b = await addAmountBased(acc, name: '现金账户', balance: 0, invested: 0);

      final s = const PortfolioCalculator().compute(await dao.getHoldings());
      final before = SnapshotRow(
        date: '2026-06-01',
        currency: 'CNY',
        totalValue: s.totalAssets,
        totalCost: s.totalCost,
        liabilities: 0,
        createdAt: DateTime(2026, 6, 1),
      );
      await service.record(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 6000,
        cashSourceId: a,
        cashTargetId: b,
        occurredAt: DateTime(2026, 6, 2, 10, 30),
      );
      final s2 = const PortfolioCalculator().compute(await dao.getHoldings());
      final after = SnapshotRow(
        date: '2026-06-02',
        currency: 'CNY',
        totalValue: s2.totalAssets,
        totalCost: s2.totalCost,
        liabilities: 0,
        createdAt: DateTime(2026, 6, 2),
      );
      final earning = const DailyEarningsCalculator()
          .compute([before, after]);
      expect(earning.last.profit, closeTo(0, 1e-6),
          reason: '转账当天（平盘）今日盈亏必须为 0 —— 否则就是同一天的假亏损/假收益');
    });
  });

  group('随机化属性测试：任意转账序列守恒', () {
    test('40 笔随机转账（含浮盈账户），每笔之后市值/成本/收益恒等于基线',
        () async {
      final acc = await addAccount('A');
      final ids = <int>[];
      final rnd = Random(42);
      // 三个带不同浮盈率的账户。
      for (var i = 0; i < 3; i++) {
        final balance = 5000.0 + rnd.nextDouble() * 5000;
        final invested = balance * (0.6 + rnd.nextDouble() * 0.3);
        ids.add(await addAmountBased(acc,
            name: '账户$i', balance: balance, invested: invested));
      }
      final v0 = await liveValue();
      final c0 = await liveCost();
      final p0 = await liveProfit();

      for (var step = 0; step < 40; step++) {
        final src = ids[rnd.nextInt(ids.length)];
        final dst = ids.where((x) => x != src).toList()[rnd.nextInt(2)];
        final srcHolding = await holding(src);
        final amount =
            (1 + rnd.nextInt(1000))
                .toDouble()
                .clamp(1.0, srcHolding.quantity - 1)
                .toDouble();
        final r = await service.record(
          accountId: acc,
          type: TransactionType.transferOut,
          amount: amount,
          cashSourceId: src,
          cashTargetId: dst,
        );
        expect(r.ok, isTrue,
            reason: '第 $step 笔转账失败：${r.message}');
        // 转账后：每个账户余额非负、总市值/总成本/总收益与基线完全一致。
        for (final id in ids) {
          final h = await holding(id);
          expect(h.quantity, greaterThanOrEqualTo(-1e-9),
              reason: '第 $step 笔转账后账户余额出现负数');
          expect(h.costPrice, greaterThanOrEqualTo(-1e-9),
              reason: '第 $step 笔转账后账户本金出现负数');
        }
        expect(await liveValue(), closeTo(v0, 1e-6),
            reason: '第 $step 笔转账变更了总市值');
        expect(await liveCost(), closeTo(c0, 1e-6),
            reason: '第 $step 笔转账变更了总成本');
        expect(await liveProfit(), closeTo(p0, 1e-6),
            reason: '第 $step 笔转账变更了总收益');
      }
    });
  });
}