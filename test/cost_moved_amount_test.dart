import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_cost.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/domain/smooth_history.dart';
import 'package:asset_tracker/domain/transaction_service.dart';

/// Regression tests for the two defects found in the 2026-09-20 scan that
/// share one root cause — a `costPrice` of 0 meaning both "genuinely zero
/// principal" and "never recorded":
///
/// 1. `_applyCashMove` read the *raw* column and clamped at 0, while the
///    transfer path had already moved to the effective cost plus a
///    proportional share. Income on an account with no recorded principal
///    invented a whole balance worth of cost; spending more than the
///    recorded principal pinned it to 0 and the totals re-read that 0 as
///    the remaining balance.
/// 2. The history replay re-derived the moved principal from the raw
///    `amount`, so a rebuilt history back-computed a wrong pre-transfer
///    principal (off by the account's unrealized gain).
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

  Future<int> addCash({
    required int accountId,
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

  Future<double> liveProfit() async {
    final s = const PortfolioCalculator()
        .compute(await dao.getHoldings(), cnyRates: const {});
    return s.totalAssets + s.totalLiabilities - s.totalCost;
  }

  Future<HoldingRow> holding(int id) async =>
      (await dao.getHoldings()).firstWhere((h) => h.id == id);

  group('现金收支按「有效本金 + 按比例移动」记账', () {
    test('未记录本金的账户收收入：本金随余额一起增加，不凭空造出收益', () async {
      final acc = await addAccount('支付宝');
      // Balance 10,000 with no recorded principal. `effectiveCostOf` reads
      // that as the balance itself, so the implied gain is 0.
      final cash = await addCash(
          accountId: acc, name: '现金', balance: 10000, invested: 0,
          type: AssetType.cash);
      expect(await liveProfit(), closeTo(0, 1e-6));

      await service.record(
        accountId: acc,
        type: TransactionType.income,
        amount: 500,
        cashTargetId: cash,
      );

      final h = await holding(cash);
      expect(h.quantity, closeTo(10500, 1e-6));
      // Reading the raw 0 column would have written `0 + 500 = 500` and the
      // totals would then treat the whole 10,500 balance as gain.
      expect(h.costPrice, closeTo(10500, 1e-6));
      expect(effectiveCostOf(h), closeTo(h.quantity, 1e-6));
      expect(await liveProfit(), closeTo(0, 1e-6),
          reason: '收入是资本流入，不是收益');
    });

    test('支出超过已记录本金：按比例带走本金，0 不被误读为「未记录」', () async {
      final acc = await addAccount('支付宝');
      final cash = await addCash(
          accountId: acc, name: '现金', balance: 10000, invested: 3000,
          type: AssetType.cash);
      expect(await liveProfit(), closeTo(7000, 1e-6));

      await service.record(
        accountId: acc,
        type: TransactionType.expense,
        amount: 5000,
        cashTargetId: cash,
      );

      final h = await holding(cash);
      expect(h.quantity, closeTo(5000, 1e-6));
      // A flat `3000 - 5000` clamped to 0 became the "never recorded"
      // sentinel, and the totals replaced it with the remaining 5,000 —
      // erasing the account's whole gain. The proportional move keeps the
      // gain rate (70%): 5,000 left carrying 1,500 of principal.
      expect(h.costPrice, closeTo(1500, 1e-6));
      expect(await liveProfit(), closeTo(3500, 1e-6));
    });

    test('全额取出后本金归零，0 在此处确实是「真的没有本金」', () async {
      final acc = await addAccount('支付宝');
      final cash = await addCash(
          accountId: acc, name: '余额宝', balance: 167915.02, invested: 165398.79);

      await service.record(
        accountId: acc,
        type: TransactionType.expense,
        amount: 167915.02,
        cashTargetId: cash,
      );

      final h = await holding(cash);
      expect(h.quantity, closeTo(0, 1e-6));
      expect(h.costPrice, closeTo(0, 1e-6));
      // Balance 0 => effectiveCostOf is 0 as well, so the two readings of
      // "0" agree here. This is the case that must keep working.
      expect(effectiveCostOf(h), closeTo(0, 1e-6));
    });
  });

  group('历史重放读取写入时记录的实际移动本金', () {
    test('转账记录的 costMovedAmount 是按比例的本金，而不是整笔金额', () async {
      final acc = await addAccount('支付宝');
      final a = await addCash(
          accountId: acc, name: 'A', balance: 10000, invested: 8000,
          type: AssetType.cash);
      final b = await addCash(
          accountId: acc, name: 'B', balance: 0, invested: 0,
          type: AssetType.cash);

      await service.record(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 10000,
        cashSourceId: a,
        cashTargetId: b,
        occurredAt: DateTime(2026, 6, 1, 10),
      );

      final txn = (await dao.getTransactions()).single;
      expect(txn.costMovedAmount, closeTo(8000, 1e-6));
    });

    test('重建历史时，转账前的本金复原为按比例的本金', () async {
      final acc = await addAccount('支付宝');
      final a = await addCash(
          accountId: acc, name: 'A', balance: 10000, invested: 8000,
          type: AssetType.cash);
      final b = await addCash(
          accountId: acc, name: 'B', balance: 0, invested: 0,
          type: AssetType.cash);

      await service.record(
        accountId: acc,
        type: TransactionType.transferOut,
        amount: 10000,
        cashSourceId: a,
        cashTargetId: b,
        occurredAt: DateTime(2026, 6, 1, 10),
      );

      final ha = await holding(a);
      final flows = await dao.getTransactionsForHolding(a);
      final principal = const SmoothHistoryCalculator().amountPrincipal(
        ha,
        flows,
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 9, 20),
      );

      // Re-deriving the delta from the raw 10,000 back-computed a
      // pre-transfer principal of 10,000 — 2,000 more than the 8,000 the
      // write side actually moved, shifting every replayed day before the
      // transfer by the account's unrealized gain.
      expect(principal['2026-05-31'], closeTo(8000, 1e-6));
      expect(principal['2026-06-01'], closeTo(0, 1e-6));
      // And it must agree with the live account, i.e. the replay is
      // consistent with where the write side landed.
      expect(principal['2026-06-01'], closeTo(ha.costPrice, 1e-6));
    });
  });
}
