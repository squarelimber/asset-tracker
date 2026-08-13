import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/rate_series.dart';
import 'package:asset_tracker/domain/transaction_service.dart';

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

  Future<int> addHolding({
    required int accountId,
    required String name,
    required AssetType type,
    double quantity = 0,
    double costPrice = 0,
    double latestPrice = 0,
    String? symbol,
  }) {
    return dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: name,
      assetType: type.storageName,
      marketSource: Value(type.isMarketLinked ? 'sina' : 'manual'),
      symbol: symbol == null ? const Value.absent() : Value(symbol),
      quantity: Value(quantity),
      costPrice: Value(costPrice),
      latestPrice: Value(latestPrice),
      currency: const Value('CNY'),
    ));
  }

  group('buy', () {
    test('increases quantity with moving average cost', () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 100, costPrice: 10, latestPrice: 12,
      );
      // Buy 100 @ 20.
      final r = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 100, price: 20, amount: 2000,
      );
      expect(r.ok, isTrue);
      final h = (await dao.getHolding(fund))!;
      expect(h.quantity, 200);
      expect(h.costPrice, closeTo(15, 1e-9)); // (100*10+2000)/200
    });

    test('with cash source reduces the cash holding balance', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 100, price: 20, amount: 2000, cashSourceId: cash,
      );
      final cashAfter = (await dao.getHolding(cash))!;
      expect(cashAfter.quantity, 3000);
      // Invested moves with the balance: the cash return rate is immune to
      // buying (money left the cash pool for the security's cost basis).
      expect(cashAfter.costPrice, 3000);
    });
  });

  group('sell', () {
    test('reduces quantity, cost unchanged, credits cash target', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 200, costPrice: 15, latestPrice: 20,
      );
      final r = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.sell,
        quantity: 50, price: 20, amount: 1000, cashTargetId: cash,
      );
      expect(r.ok, isTrue);
      final fundAfter = (await dao.getHolding(fund))!;
      expect(fundAfter.quantity, 150);
      expect(fundAfter.costPrice, 15);
      final cashAfter = (await dao.getHolding(cash))!;
      expect(cashAfter.quantity, 1000);
      expect(cashAfter.costPrice, 1000); // invested moves with the credit
    });

    test('rejects selling more than owned', () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 10, costPrice: 10, latestPrice: 10,
      );
      final r = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.sell,
        quantity: 100, price: 10, amount: 1000,
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('超过'));
    });
  });

  group('transfer', () {
    test('moves cash between holdings', () async {
      final acc = await addAccount('A');
      final a = await addHolding(
        accountId: acc, name: '现金A', type: AssetType.bankDeposit,
        quantity: 10000, costPrice: 9000, latestPrice: 1,
      );
      final b = await addHolding(
        accountId: acc, name: '现金B', type: AssetType.liquidWealth,
        quantity: 1000, costPrice: 1000, latestPrice: 1,
      );
      final r = await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 3000, cashSourceId: a, cashTargetId: b,
      );
      expect(r.ok, isTrue);
      expect((await dao.getHolding(a))!.quantity, 7000);
      expect((await dao.getHolding(b))!.quantity, 4000);
      // Invested moves with the transfer so return rates stay undistorted.
      expect((await dao.getHolding(a))!.costPrice, 6000);
      expect((await dao.getHolding(b))!.costPrice, 4000);
    });

    test('repaying a liability reduces both balances', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final loan = await addHolding(
        accountId: acc, name: '贷款', type: AssetType.liability,
        quantity: 2000, costPrice: 2000, latestPrice: 1,
      );
      // Repay 1500: cash falls, debt falls.
      await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 1500, cashSourceId: cash, cashTargetId: loan,
      );
      expect((await dao.getHolding(cash))!.quantity, 3500);
      expect((await dao.getHolding(loan))!.quantity, 500);
    });

    test('borrowing increases cash and debt', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 1000, costPrice: 1000, latestPrice: 1,
      );
      final loan = await addHolding(
        accountId: acc, name: '贷款', type: AssetType.liability,
        quantity: 3000, costPrice: 3000, latestPrice: 1,
      );
      // Loan payout of 2000: cash rises, debt rises.
      await service.record(
        accountId: acc, type: TransactionType.transferIn,
        amount: 2000, cashSourceId: loan, cashTargetId: cash,
      );
      expect((await dao.getHolding(cash))!.quantity, 3000);
      expect((await dao.getHolding(loan))!.quantity, 5000);
    });

    test('repaying a liability keeps the cash return rate unchanged', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 10000, costPrice: 10000, latestPrice: 1,
      );
      final loan = await addHolding(
        accountId: acc, name: '贷款', type: AssetType.liability,
        quantity: 5000, costPrice: 1, latestPrice: 1,
      );
      final before = RateSeriesCalculator.dailyRate(10000, 10000);
      // Repay 3000: both balance and invested fall together.
      await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 3000, cashSourceId: cash, cashTargetId: loan,
      );
      final afterRow = (await dao.getHolding(cash))!;
      expect(afterRow.quantity, 7000);
      expect(afterRow.costPrice, 7000);
      final after =
          RateSeriesCalculator.dailyRate(afterRow.quantity, afterRow.costPrice);
      expect(after - before, closeTo(0, 1e-9));
    });

    test('repayment shows up in the liability detail query', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final card = await addHolding(
        accountId: acc, name: '信用卡', type: AssetType.liability,
        quantity: 2000, costPrice: 1, latestPrice: 1,
      );
      await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 800, cashSourceId: cash, cashTargetId: card,
      );
      // The transfer has holdingId = null but references the card as the
      // cash target; the detail query must still return it.
      final rows = await dao.getTransactionsForHolding(card);
      expect(rows, hasLength(1));
      expect(rows.single.amount, 800);
    });
  });

  group('remove transfer rollback', () {
    test('legacy transfer (costMoved=false) only restores the balance', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 7000, costPrice: 10000, latestPrice: 1, // legacy: cost unsynced
      );
      final loan = await addHolding(
        accountId: acc, name: '贷款', type: AssetType.liability,
        quantity: 3000, costPrice: 1, latestPrice: 1,
      );
      final id = await dao.createTransaction(TransactionsCompanion.insert(
        accountId: acc,
        type: 'transfer_out',
        amount: 3000,
        cashSourceId: Value(cash),
        cashTargetId: Value(loan),
        occurredAt: DateTime(2026, 1, 1),
        costMoved: const Value(false),
      ));
      await service.remove(id);
      final h = (await dao.getHolding(cash))!;
      expect(h.quantity, 10000);
      expect(h.costPrice, 10000); // cost untouched for legacy transfers
    });

    test('new transfer (costMoved=true) rolls back balance and cost', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 10000, costPrice: 10000, latestPrice: 1,
      );
      final loan = await addHolding(
        accountId: acc, name: '贷款', type: AssetType.liability,
        quantity: 3000, costPrice: 1, latestPrice: 1,
      );
      await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 3000, cashSourceId: cash, cashTargetId: loan,
      );
      expect((await dao.getHolding(cash))!.quantity, 7000);
      final txns = await dao.getTransactions();
      await service.remove(txns.single.id);
      final h = (await dao.getHolding(cash))!;
      expect(h.quantity, 10000);
      expect(h.costPrice, 10000); // cost moves back together
    });
  });

  group('consume', () {
    test('credit-card spend increases the liability balance', () async {
      final acc = await addAccount('A');
      final card = await addHolding(
        accountId: acc, name: '信用卡', type: AssetType.liability,
        quantity: 1200, costPrice: 1200, latestPrice: 1,
      );
      final r = await service.record(
        accountId: acc, holdingId: card, type: TransactionType.consume,
        amount: 800, note: '超市购物',
      );
      expect(r.ok, isTrue);
      final h = (await dao.getHolding(card))!;
      expect(h.quantity, 2000);
      // No cash holding was touched: costPrice stays as the principal.
      expect(h.costPrice, 1200);
    });

    test('rejects consume on a non-liability holding', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final r = await service.record(
        accountId: acc, holdingId: cash, type: TransactionType.consume,
        amount: 100,
      );
      expect(r.ok, isFalse);
      expect((await dao.getHolding(cash))!.quantity, 5000);
    });

    test('removing a consume reverses the balance', () async {
      final acc = await addAccount('A');
      final card = await addHolding(
        accountId: acc, name: '信用卡', type: AssetType.liability,
        quantity: 2000, costPrice: 2000, latestPrice: 1,
      );
      final r = await service.record(
        accountId: acc, holdingId: card, type: TransactionType.consume,
        amount: 500,
      );
      expect(r.ok, isTrue);
      expect((await dao.getHolding(card))!.quantity, 2500);
      final txns = await dao.getTransactions();
      await service.remove(txns.single.id);
      expect((await dao.getHolding(card))!.quantity, 2000);
    });
  });

  group('income/expense/dividend', () {
    test('income adds cash AND invested (excluded from P/L)', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 10000, costPrice: 8000, latestPrice: 1,
      );
      await service.record(
        accountId: acc, type: TransactionType.income,
        amount: 2000, cashTargetId: cash,
      );
      final h = (await dao.getHolding(cash))!;
      expect(h.quantity, 12000);
      expect(h.costPrice, 10000); // profit stays 2000 (unchanged)
    });

    test('expense reduces cash AND invested', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 10000, costPrice: 10000, latestPrice: 1,
      );
      await service.record(
        accountId: acc, type: TransactionType.expense,
        amount: 3000, cashTargetId: cash,
      );
      final h = (await dao.getHolding(cash))!;
      expect(h.quantity, 7000);
      expect(h.costPrice, 7000);
    });

    test('dividend adds cash but keeps invested', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 1000, costPrice: 900, latestPrice: 1,
      );
      await service.record(
        accountId: acc, type: TransactionType.dividend,
        amount: 100, cashTargetId: cash,
      );
      final h = (await dao.getHolding(cash))!;
      expect(h.quantity, 1100);
      expect(h.costPrice, 900); // counts as gain
    });

    test('dividend reduces the share holding cost (cost-basis method)', () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 1000, costPrice: 1.5, latestPrice: 1.5,
      );
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      // 0.5/unit dividend: NAV drops 1.5 -> 1.0 ex-dividend.
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.dividend,
        amount: 500, cashTargetId: cash,
      );
      // Simulate the ex-dividend price drop.
      await dao.updateHoldingPrice(fund, 1.0);
      final f = (await dao.getHolding(fund))!;
      // Cost 1.5 -> 1.0, so the return rate stays at 0 instead of -33%.
      expect(f.costPrice, closeTo(1.0, 1e-9));
      final rate =
          RateSeriesCalculator.dailyRate(f.quantity * f.latestPrice, f.quantity * f.costPrice);
      expect(rate, closeTo(0, 1e-9));
      final c = (await dao.getHolding(cash))!;
      expect(c.quantity, 500);
    });

    test('removing a dividend restores the share cost', () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 1000, costPrice: 1.5, latestPrice: 1.5,
      );
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.dividend,
        amount: 500, cashTargetId: cash,
      );
      final txnId = (await dao.getTransactions()).single.id;
      await service.remove(txnId);
      final f = (await dao.getHolding(fund))!;
      expect(f.costPrice, closeTo(1.5, 1e-9));
      expect((await dao.getHolding(cash))!.quantity, 0);
    });
  });

  group('deleteHolding orphan cleanup', () {
    test('removing a cash holding deletes transfers referencing it', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final card = await addHolding(
        accountId: acc, name: '信用卡', type: AssetType.liability,
        quantity: 2000, costPrice: 1, latestPrice: 1,
      );
      await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 800, cashSourceId: cash, cashTargetId: card,
      );
      expect(await dao.getTransactions(), hasLength(1));

      await dao.deleteHolding(cash);

      // The transfer referencing the deleted holding must not be orphaned.
      expect(await dao.getTransactions(), isEmpty);
      expect(await dao.getHolding(card), isNot(null));
    });
  });

  group('remove', () {
    test('removing a buy reverses quantity/cost and refunds cash', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 3000, costPrice: 3000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 100, costPrice: 10, latestPrice: 10,
      );
      final id = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 100, price: 20, amount: 2000, cashSourceId: cash,
      );
      expect(id.ok, isTrue);
      final txnId = (await dao.getTransactions()).single.id;

      final r = await service.remove(txnId);
      expect(r.ok, isTrue);
      final fundAfter = (await dao.getHolding(fund))!;
      expect(fundAfter.quantity, 100);
      expect(fundAfter.costPrice, closeTo(10, 1e-9));
      // Cash was debited 2000 on buy and refunded on remove: 3000.
      expect((await dao.getHolding(cash))!.quantity, 3000);
      expect(await dao.getTransactions(), isEmpty);
    });

    test('buy with newer transactions refuses to delete', () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 10,
      );
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 100, price: 10, amount: 1000,
      );
      final firstTxnId = (await dao.getTransactions()).first.id;
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 100, price: 20, amount: 2000,
      );

      final r = await service.remove(firstTxnId);
      expect(r.ok, isFalse);
      expect(r.message, contains('更晚'));
      // Deleting the newest one works.
      final secondTxnId = (await dao.getTransactions()).last.id;
      expect((await service.remove(secondTxnId)).ok, isTrue);
      final h = (await dao.getHolding(fund))!;
      expect(h.quantity, 100);
      expect(h.costPrice, closeTo(10, 1e-9));
    });

    test('removing an expense refunds cash and invested', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 7000, costPrice: 7000, latestPrice: 1,
      );
      await service.record(
        accountId: acc, type: TransactionType.expense,
        amount: 3000, cashTargetId: cash,
      );
      final txnId = (await dao.getTransactions()).single.id;
      await service.remove(txnId);
      final h = (await dao.getHolding(cash))!;
      expect(h.quantity, 7000);
      expect(h.costPrice, 7000);
    });
  });
}
