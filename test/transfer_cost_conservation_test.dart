import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/daily_earnings.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/domain/transaction_service.dart';
import 'package:asset_tracker/services/snapshot_service.dart';

/// Regression tests for the 2026-09-18 "transfer shows a phantom loss"
/// bug: `_applyBalanceMove` wrote `costPrice + delta` **clamped at 0**, so
/// moving out more than the recorded principal pinned the invested amount
/// to 0 — which the totals then re-read as "no invested amount recorded"
/// and replaced with the whole remaining balance. The portfolio's total
/// cost jumped by the account's unrealized gain, and the overview reported
/// exactly that as a loss on the transfer day (and on every launch that
/// rewrote the day from the live holdings).
///
/// Real shape of the report: 余额宝 held 167,915.02 with 165,398.79
/// recorded as invested; it was emptied into 现金账户 in one transfer.
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

  Future<int> addAccount(String name) {
    return dao.createAccount(AccountsCompanion.insert(name: name, type: 'general'));
  }

  /// An amount-based (cash-like) holding: quantity = balance, costPrice =
  /// cumulative invested amount.
  Future<int> addCash({
    required int accountId,
    required String name,
    required double balance,
    required double invested,
    AssetType type = AssetType.bankDeposit,
    DateTime? purchaseDate,
  }) {
    return dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: name,
      assetType: type.storageName,
      marketSource: const Value('manual'),
      quantity: Value(balance),
      costPrice: Value(invested),
      latestPrice: const Value(1),
      purchaseDate: Value(purchaseDate ?? DateTime(2026, 1, 1)),
    ));
  }

  /// What the overview card shows: net worth (assets + liabilities) minus
  /// the total cost. An internal transfer moves money between two holdings
  /// of the same portfolio, so this number must not change at all.
  Future<double> liveProfit() async {
    final summary = const PortfolioCalculator()
        .compute(await dao.getHoldings(), cnyRates: const {});
    return summary.totalAssets + summary.totalLiabilities - summary.totalCost;
  }

  Future<double> totalCost() async {
    final summary = const PortfolioCalculator()
        .compute(await dao.getHoldings(), cnyRates: const {});
    return summary.totalCost;
  }

  group('转账必须守恒成本（不再凭空创造/销毁成本）', () {
    test('清空一个余额高于累计投入的账户：总成本与总收益分毫不动', () async {
      final acc = await addAccount('支付宝');
      // The reported case: a money-market account that has accrued gains.
      final yuEBao = await addCash(
        accountId: acc, name: '余额宝', balance: 167915.02, invested: 165398.79);
      final cash = await addCash(
        accountId: acc, name: '现金账户', balance: 78932.11, invested: 78932.11,
        type: AssetType.cash);

      final profitBefore = await liveProfit();
      final costBefore = await totalCost();
      expect(costBefore, closeTo(165398.79 + 78932.11, 1e-6));

      // Empty the account: the whole balance goes to the cash holding.
      final r = await service.record(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 167915.02,
        cashSourceId: yuEBao,
        cashTargetId: cash,
      );
      expect(r.ok, isTrue);

      final source = (await dao.getHolding(yuEBao))!;
      final target = (await dao.getHolding(cash))!;
      // Money moved …
      expect(source.quantity, closeTo(0, 1e-6));
      expect(target.quantity, closeTo(78932.11 + 167915.02, 1e-6));
      // … and so did the invested amount, by the same number on both legs:
      // the source gives up its whole principal, the target receives exactly
      // that (never the full balance, which is what invented the gain as a
      // loss).
      expect(source.costPrice, closeTo(0, 1e-6));
      expect(target.costPrice, closeTo(78932.11 + 165398.79, 1e-6));

      // The invariant that broke: an internal transfer is not a gain or a
      // loss. Before the fix the total cost jumped by 167,915.02 −
      // 165,398.79 = 2,516.23 and the card showed −2,516.
      expect(await totalCost(), closeTo(costBefore, 1e-6));
      expect(await liveProfit(), closeTo(profitBefore, 1e-6));
    });

    test('转出金额超过累计投入：不产生假亏损', () async {
      final acc = await addAccount('A');
      final source = await addCash(
        accountId: acc, name: '现金A', balance: 150000, invested: 50000);
      final target = await addCash(
        accountId: acc, name: '现金B', balance: 0, invested: 0,
        type: AssetType.liquidWealth);

      final before = await liveProfit();
      await service.record(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 100000,
        cashSourceId: source,
        cashTargetId: target,
      );

      final s = (await dao.getHolding(source))!;
      final t = (await dao.getHolding(target))!;
      expect(s.quantity, closeTo(50000, 1e-6));
      // The principal travels pro-rata: 50,000 × (100,000 / 150,000) =
      // 33,333.33 leaves the source (which keeps 16,666.67) and lands on the
      // target — the same number on both legs. The old rule clamped the
      // source at 0 instead, and 0 was then re-read as "unset" and replaced
      // with the remaining balance (50,000): a phantom cost of +50,000, i.e.
      // a −50,000 loss on the card.
      final moved = 50000 * (100000 / 150000);
      expect(s.costPrice, closeTo(50000 - moved, 1e-6));
      expect(t.costPrice, closeTo(moved, 1e-6));
      expect(await liveProfit(), closeTo(before, 1e-6));
    });

    test('目标账户没记过累计投入：不会被转账重置掉隐含本金', () async {
      final acc = await addAccount('A');
      final source = await addCash(
        accountId: acc, name: '现金A', balance: 10000, invested: 10000);
      // Never recorded an invested amount: the app reads the balance as the
      // principal, so receiving 500 must add to 1,000, not replace it.
      final target = await addCash(
        accountId: acc, name: '现金B', balance: 1000, invested: 0,
        type: AssetType.cash);

      final before = await liveProfit();
      await service.record(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 500,
        cashSourceId: source,
        cashTargetId: target,
      );

      expect((await dao.getHolding(target))!.costPrice, closeTo(1500, 1e-6));
      expect(await liveProfit(), closeTo(before, 1e-6));
    });

    test('转账不会扭曲账户的收益率（本金按比例同行）', () async {
      final acc = await addAccount('A');
      final source = await addCash(
        accountId: acc, name: '现金A', balance: 10000, invested: 9000);
      final target = await addCash(
        accountId: acc, name: '现金B', balance: 1000, invested: 1000,
        type: AssetType.cash);

      await service.record(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 3000,
        cashSourceId: source,
        cashTargetId: target,
      );

      final s = (await dao.getHolding(source))!;
      final t = (await dao.getHolding(target))!;
      // 10,000/9,000 (11.11% gain) ships 3,000 away, so 30% of the
      // principal goes with it: 2,700 — the remaining account keeps 11.11%.
      // Moving a flat 3,000 would have pushed it to 16.7%.
      expect(s.costPrice, closeTo(6300, 1e-6));
      expect(t.costPrice, closeTo(3700, 1e-6));
      expect((s.quantity - s.costPrice) / s.quantity,
          closeTo((10000 - 9000) / 10000, 1e-12));
      expect(s.quantity + t.quantity, closeTo(11000, 1e-6));
      expect(s.costPrice + t.costPrice, closeTo(10000, 1e-6));
    });

    test('删除转账会原样回滚（成本不被二次钳制）', () async {
      final acc = await addAccount('A');
      final source = await addCash(
        accountId: acc, name: '现金A', balance: 10000, invested: 2000);
      final target = await addCash(
        accountId: acc, name: '现金B', balance: 0, invested: 0,
        type: AssetType.cash);

      await service.record(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 10000, // empties an account whose principal is only 2,000
        cashSourceId: source,
        cashTargetId: target,
      );
      final txn = (await dao.getTransactions()).single;
      await service.remove(txn.id);

      final s = (await dao.getHolding(source))!;
      final t = (await dao.getHolding(target))!;
      expect(s.quantity, closeTo(10000, 1e-6));
      expect(s.costPrice, closeTo(2000, 1e-6));
      expect(t.quantity, closeTo(0, 1e-6));
      expect(t.costPrice, closeTo(0, 1e-6));
    });
  });

  group('快照口径：转账当天不得出现假盈亏', () {
    test('清空余额宝当天，今日盈亏仍是 0', () async {
      final acc = await addAccount('支付宝');
      final yuEBao = await addCash(
        accountId: acc, name: '余额宝', balance: 167915.02, invested: 165398.79);
      final cash = await addCash(
        accountId: acc, name: '现金账户', balance: 78932.11, invested: 78932.11,
        type: AssetType.cash);

      // Yesterday's row, written from the live holdings like the app does.
      var now = DateTime(2026, 9, 17, 21);
      final snapshot = SnapshotService(dao, clock: () => now);
      await snapshot.ensureTodaySnapshot(force: true);

      // Today: empty the account, then rewrite today's row (the app does
      // this on every launch and after every successful price refresh).
      now = DateTime(2026, 9, 18, 10);
      await service.record(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 167915.02,
        cashSourceId: yuEBao,
        cashTargetId: cash,
      );
      await snapshot.ensureTodaySnapshot(force: true);

      final earning = todayEarningOf(await dao.getSnapshots(), now: now)!;
      // Before the fix this read −2,516.23: the account's unrealized gain,
      // reported as a loss the moment the account was emptied.
      expect(earning.profit, closeTo(0, 1e-6));
    });
  });
}
