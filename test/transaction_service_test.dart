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

  /// Portfolio total cost basis (same convention as [PortfolioCalculator]):
  /// share-based = quantity x unit cost; amount-based = the recorded
  /// (or implied) cumulative principal. Used to assert cost conservation.
  Future<double> portfolioCost() async {
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
    test('reduces quantity, cost unchanged, credits cash target at sold principal',
        () async {
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
      // Proceeds land in full, but only the *sold principal* (50 x 15 = 750)
      // enters the invested amount — the 250 gain stays unrealized on the
      // cash account, so the portfolio's total cost is conserved and the
      // sell day shows no phantom loss. Booking the full 1000 re-books the
      // gain as principal (2026-09-24「直接赎回到现金也资产算错」report).
      expect(cashAfter.costPrice, closeTo(750, 1e-6));
      // Sell into a tracked cash holding: an internal movement, not a
      // realization (excluded from the realized-profit estimates).
      expect((await dao.getTransactions()).single.internalMove, isTrue);
    });

    test('sell without a cash target (“回款不入账”) realizes', () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 200, costPrice: 15, latestPrice: 20,
      );
      final r = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.sell,
        quantity: 50, price: 20, amount: 1000,
      );
      expect(r.ok, isTrue);
      final row = (await dao.getTransactions()).single;
      expect(row.internalMove, isFalse,
          reason: '回款不入账的卖出是真实退出（钱离开追踪范围），仍计入已实现');
      expect((await dao.getHolding(fund))!.quantity, 150);
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

    test('full sell-out keeps the unit cost for realized-gain estimation',
        () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 100, costPrice: 10, latestPrice: 12,
      );
      final r = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.sell,
        quantity: 100, price: 12, amount: 1200,
      );
      expect(r.ok, isTrue);
      final fundAfter = (await dao.getHolding(fund))!;
      expect(fundAfter.quantity, 0);
      expect(fundAfter.costPrice, 10);
    });

    test('buy-back after sell-out restarts the cost at the new price',
        () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 100, costPrice: 10, latestPrice: 12,
      );
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.sell,
        quantity: 100, price: 12, amount: 1200,
      );
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 50, price: 20, amount: 1000,
      );
      final fundAfter = (await dao.getHolding(fund))!;
      expect(fundAfter.quantity, 50);
      expect(fundAfter.costPrice, closeTo(20, 1e-9));
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
      // Invested moves with the balance so the transfer neither distorts the
      // return rate of A (10,000/9,000 = 11.11% before and after) nor the
      // portfolio's total cost. The share of the principal that leaves is
      // proportional to the money moved: 9,000 × (3,000 / 10,000) = 2,700,
      // not a flat 3,000 — moving a flat 3,000 would have pushed A's gain to
      // 16.7% and, once the principal ran out, invented cost for B.
      expect((await dao.getHolding(a))!.costPrice, closeTo(6300, 1e-6));
      expect((await dao.getHolding(b))!.costPrice, closeTo(3700, 1e-6));
      expect((await dao.getHolding(a))!.costPrice +
          (await dao.getHolding(b))!.costPrice, closeTo(10000, 1e-6));
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

  group('split', () {
    test('1:2 split doubles quantity and halves unit cost', () async {
      final acc = await addAccount('A');
      final etf = await addHolding(
        accountId: acc, name: '半导体', type: AssetType.etf,
        quantity: 109300, costPrice: 2.7, latestPrice: 2.7,
      );
      await service.record(
        accountId: acc, holdingId: etf, type: TransactionType.split,
        amount: 2.0,
      );
      final h = (await dao.getHolding(etf))!;
      expect(h.quantity, 218600);
      expect(h.costPrice, closeTo(1.35, 1e-9));
    });

    test('rejects splits on non-share holdings', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 1000, costPrice: 1000, latestPrice: 1,
      );
      final r = await service.record(
        accountId: acc, holdingId: cash, type: TransactionType.split,
        amount: 2.0,
      );
      expect(r.ok, isFalse);
    });

    test('removing a split reverses the ratio', () async {
      final acc = await addAccount('A');
      final etf = await addHolding(
        accountId: acc, name: '半导体', type: AssetType.etf,
        quantity: 109300, costPrice: 2.7, latestPrice: 2.7,
      );
      await service.record(
        accountId: acc, holdingId: etf, type: TransactionType.split,
        amount: 2.0,
      );
      final txnId = (await dao.getTransactions()).single.id;
      await service.remove(txnId);
      final h = (await dao.getHolding(etf))!;
      expect(h.quantity, 109300);
      expect(h.costPrice, closeTo(2.7, 1e-9));
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

    test('removing the last buy keeps the unit cost on the emptied holding',
        () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 10,
      );
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 100, price: 10, amount: 1000,
      );
      final txnId = (await dao.getTransactions()).single.id;
      expect((await service.remove(txnId)).ok, isTrue);
      final h = (await dao.getHolding(fund))!;
      expect(h.quantity, 0);
      expect(h.costPrice, 10);
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

  group('recordBuyFundedByHolding (用已持仓产品出资买入)', () {
    test('amount-based source: debits balance+invested, target moving average, 2 rows',
        () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 100, costPrice: 10, latestPrice: 12,
      );
      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: cash, targetHoldingId: fund,
        targetQuantity: 50, targetPrice: 20, amount: 1000,
      );
      expect(r.ok, isTrue);
      final cashAfter = (await dao.getHolding(cash))!;
      expect(cashAfter.quantity, 4000);
      expect(cashAfter.costPrice, 4000); // invested moves with the balance
      final fundAfter = (await dao.getHolding(fund))!;
      expect(fundAfter.quantity, 150);
      expect(fundAfter.costPrice, closeTo((100 * 10 + 1000) / 150, 1e-9));
      // Two rows: sell (source) + buy (target), same timestamp.
      final rows = await dao.getTransactions();
      expect(rows, hasLength(2));
      final sell = rows.firstWhere((t) => t.type == 'sell');
      expect(sell.holdingId, cash);
      expect(sell.quantity, 1000); // amount-based: quantity == amount
      expect(sell.price, 1);
      expect(sell.note, '赎回购买 基金');
      final buy = rows.firstWhere((t) => t.type == 'buy');
      expect(buy.holdingId, fund);
      expect(buy.quantity, 50);
      expect(buy.price, 20);
      expect(buy.note, '由 现金 出资');
      expect(sell.occurredAt, buy.occurredAt);
      // Internal legs: the proceeds stay in the portfolio.
      expect(sell.internalMove, isTrue);
      expect(buy.internalMove, isTrue);
    });

    test('share-based source: cost basis follows the units, total cost conserved',
        () async {
      final acc = await addAccount('A');
      final mmf = await addHolding(
        accountId: acc, name: '天天宝', type: AssetType.mutualFund,
        quantity: 1000, costPrice: 1, latestPrice: 2,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      final before = await portfolioCost();
      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: mmf, targetHoldingId: fund,
        targetQuantity: 100, targetPrice: 10, amount: 1000,
      );
      expect(r.ok, isTrue);
      final mmfAfter = (await dao.getHolding(mmf))!;
      expect(mmfAfter.quantity, 500); // 1000 - 1000/2
      expect(mmfAfter.costPrice, 1); // unit cost unchanged
      final fundAfter = (await dao.getHolding(fund))!;
      expect(fundAfter.quantity, 100);
      // The redeemed units carried 500 x 1 = 500 of principal into the new
      // position. NOT the market amount 1000: booking the unrealized gain
      // as fresh principal inflates total cost and shows up as a same-day
      // loss of exactly that gain.
      expect(fundAfter.costPrice, closeTo(5, 1e-9));
      // Total cost is conserved: money moved product -> product.
      expect(await portfolioCost(), closeTo(before, 1e-6));
      final sell =
          (await dao.getTransactions()).firstWhere((t) => t.type == 'sell');
      expect(sell.quantity, 500);
      expect(sell.price, 2);
      expect(sell.internalMove, isTrue);
    });

    test('unit falls back to costPrice when latestPrice is 0', () async {
      final acc = await addAccount('A');
      final mmf = await addHolding(
        accountId: acc, name: '天天宝', type: AssetType.mutualFund,
        quantity: 100, costPrice: 4, latestPrice: 0,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: mmf, targetHoldingId: fund,
        targetQuantity: 10, targetPrice: 10, amount: 200,
      );
      expect(r.ok, isTrue);
      expect((await dao.getHolding(mmf))!.quantity, 50); // 100 - 200/4
      final sell =
          (await dao.getTransactions()).firstWhere((t) => t.type == 'sell');
      expect(sell.price, 4);
      expect(sell.quantity, 50);
    });

    test('insufficient share-based source: rejected, no partial state', () async {
      final acc = await addAccount('A');
      final mmf = await addHolding(
        accountId: acc, name: '天天宝', type: AssetType.mutualFund,
        quantity: 100, costPrice: 1, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: mmf, targetHoldingId: fund,
        targetQuantity: 10, targetPrice: 10, amount: 500,
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('可用市值不足'));
      expect((await dao.getHolding(mmf))!.quantity, 100);
      expect((await dao.getHolding(fund))!.quantity, 0);
      expect(await dao.getTransactions(), isEmpty);
    });

    test('insufficient amount-based source: rejected, no partial state', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 500, costPrice: 500, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: cash, targetHoldingId: fund,
        targetQuantity: 10, targetPrice: 10, amount: 600,
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('余额不足'));
      expect((await dao.getHolding(cash))!.quantity, 500);
      expect((await dao.getHolding(fund))!.quantity, 0);
      expect(await dao.getTransactions(), isEmpty);
    });

    test('currency mismatch: rejected', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final usd = await dao.createHolding(HoldingsCompanion.insert(
        accountId: acc,
        name: 'USD基金',
        assetType: AssetType.mutualFund.storageName,
        marketSource: Value('sina'),
        quantity: Value(0),
        costPrice: Value(0),
        latestPrice: Value(1),
        currency: Value('USD'),
      ));
      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: cash, targetHoldingId: usd,
        targetQuantity: 10, amount: 100,
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('币种不一致'));
    });

    test('same source and target: rejected', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: cash, targetHoldingId: cash,
        targetQuantity: 10, amount: 100,
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('不能相同'));
    });

    test('liability as source: rejected', () async {
      final acc = await addAccount('A');
      final loan = await addHolding(
        accountId: acc, name: '贷款', type: AssetType.liability,
        quantity: 2000, costPrice: 2000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      final r = await service.recordBuyFundedByHolding(
        sourceHoldingId: loan, targetHoldingId: fund,
        targetQuantity: 10, amount: 100,
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('负债'));
    });

    test('removing the buy row rolls back the target only', () async {
      final acc = await addAccount('A');
      final mmf = await addHolding(
        accountId: acc, name: '天天宝', type: AssetType.mutualFund,
        quantity: 1000, costPrice: 1, latestPrice: 2,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      await service.recordBuyFundedByHolding(
        sourceHoldingId: mmf, targetHoldingId: fund,
        targetQuantity: 100, targetPrice: 10, amount: 1000,
      );
      final buy =
          (await dao.getTransactions()).firstWhere((t) => t.type == 'buy');
      expect((await service.remove(buy.id)).ok, isTrue);
      final fundAfter = (await dao.getHolding(fund))!;
      expect(fundAfter.quantity, 0);
      expect(fundAfter.costPrice, 5); // full reversal keeps the unit cost
      // The source stays redeemed: its sell row is untouched.
      expect((await dao.getHolding(mmf))!.quantity, 500);
    });

    test('removing the sell row restores the source quantity', () async {
      final acc = await addAccount('A');
      final mmf = await addHolding(
        accountId: acc, name: '天天宝', type: AssetType.mutualFund,
        quantity: 1000, costPrice: 1, latestPrice: 2,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      await service.recordBuyFundedByHolding(
        sourceHoldingId: mmf, targetHoldingId: fund,
        targetQuantity: 100, targetPrice: 10, amount: 1000,
      );
      final sell =
          (await dao.getTransactions()).firstWhere((t) => t.type == 'sell');
      expect((await service.remove(sell.id)).ok, isTrue);
      final mmfAfter = (await dao.getHolding(mmf))!;
      expect(mmfAfter.quantity, 1000);
      expect(mmfAfter.costPrice, 1);
      // The target keeps its purchase.
      expect((await dao.getHolding(fund))!.quantity, 100);
    });
  });

  group('recordRedemption (独立赎回)', () {
    test('amount-based: debits balance and invested, writes a sell row', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final r = await service.recordRedemption(
        sourceHoldingId: cash, amount: 2000, note: '赎回购买 新基金',
      );
      expect(r.ok, isTrue);
      final cashAfter = (await dao.getHolding(cash))!;
      expect(cashAfter.quantity, 3000);
      expect(cashAfter.costPrice, 3000);
      final row = (await dao.getTransactions()).single;
      expect(row.type, 'sell');
      expect(row.holdingId, cash);
      expect(row.quantity, 2000);
      expect(row.price, 1);
      expect(row.amount, 2000);
      expect(row.note, '赎回购买 新基金');
      // Proceeds fund another holding: an internal move, not a realization.
      expect(row.internalMove, isTrue);
      // The caller gets the principal that left, to carry into the new
      // holding's cost basis.
      expect(r.movedCost, closeTo(2000, 1e-6));
    });

    test('removing an amount-based redemption restores balance AND invested',
        () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.bankDeposit,
        quantity: 5000, costPrice: 3000, latestPrice: 1, // principal < balance
      );
      await service.recordRedemption(
        sourceHoldingId: cash, amount: 2000,
      );
      final h = (await dao.getHolding(cash))!;
      expect(h.quantity, closeTo(3000, 1e-6));
      // Proportional principal: 3000 * 2000/5000 = 1200 left.
      expect(h.costPrice, closeTo(1800, 1e-6));

      final row = (await dao.getTransactions()).single;
      expect(row.costMovedAmount, closeTo(1200, 1e-6));
      expect((await service.remove(row.id)).ok, isTrue);
      final restored = (await dao.getHolding(cash))!;
      expect(restored.quantity, closeTo(5000, 1e-6));
      expect(restored.costPrice, closeTo(3000, 1e-6),
          reason: 'removing the redemption must undo the principal too, '
              'otherwise the balance is back but the invested is short');
    });

    test('share-based: reduces quantity, keeps cost, unit from latestPrice',
        () async {
      final acc = await addAccount('A');
      final mmf = await addHolding(
        accountId: acc, name: '天天宝', type: AssetType.mutualFund,
        quantity: 1000, costPrice: 1, latestPrice: 2,
      );
      final r = await service.recordRedemption(
        sourceHoldingId: mmf, amount: 1000,
      );
      expect(r.ok, isTrue);
      final mmfAfter = (await dao.getHolding(mmf))!;
      expect(mmfAfter.quantity, 500);
      expect(mmfAfter.costPrice, 1);
      final row = (await dao.getTransactions()).single;
      expect(row.type, 'sell');
      expect(row.quantity, 500);
      expect(row.price, 2);
      expect(row.internalMove, isTrue);
      // The 500 units carried 500 x 1 = 500 of principal out of the source.
      expect(r.movedCost, closeTo(500, 1e-6));
    });

    test('rejects liability', () async {
      final acc = await addAccount('A');
      final loan = await addHolding(
        accountId: acc, name: '贷款', type: AssetType.liability,
        quantity: 2000, costPrice: 2000, latestPrice: 1,
      );
      final r = await service.recordRedemption(
        sourceHoldingId: loan, amount: 500,
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('负债'));
      expect(await dao.getTransactions(), isEmpty);
    });

    test('rejects insufficient source without partial state', () async {
      final acc = await addAccount('A');
      final mmf = await addHolding(
        accountId: acc, name: '天天宝', type: AssetType.mutualFund,
        quantity: 100, costPrice: 1, latestPrice: 1,
      );
      final r = await service.recordRedemption(
        sourceHoldingId: mmf, amount: 200,
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('可用市值不足'));
      expect((await dao.getHolding(mmf))!.quantity, 100);
      expect(await dao.getTransactions(), isEmpty);
    });

    test('with target writes both sell and buy legs for history', () async {
      // 赎回购买（新建持仓）：必须同时记 source 的卖出腿和 target 的买入腿，
      // 否则历史回放会把新持仓当成凭空出现（如 五年国债ETF 2026-09-24）。
      final acc = await addAccount('A');
      final mmf = await addHolding(
        accountId: acc, name: '现金账户', type: AssetType.cash,
        quantity: 200000, costPrice: 200000, latestPrice: 1,
      );
      final etf = await addHolding(
        accountId: acc, name: '五年国债ETF', type: AssetType.etf,
        quantity: 800, costPrice: 140.7, latestPrice: 140.7,
        symbol: 'sh511010',
      );
      final r = await service.recordRedemption(
        sourceHoldingId: mmf,
        amount: 112560,
        currency: 'CNY',
        targetHoldingId: etf,
        targetQuantity: 800,
        targetPrice: 140.7,
        note: '赎回购买 五年国债ETF',
      );
      expect(r.ok, isTrue, reason: 'failed: ${r.message}');

      final rows = await dao.getTransactions();
      expect(rows, hasLength(2));
      final sell = rows.firstWhere((t) => t.type == 'sell');
      final buy = rows.firstWhere((t) => t.type == 'buy');
      expect(sell.holdingId, mmf);
      expect(sell.amount, closeTo(112560, 1e-6));
      expect(sell.internalMove, isTrue);
      expect(buy.holdingId, etf);
      expect(buy.quantity, 800);
      expect(buy.amount, closeTo(112560, 1e-6));
      expect(buy.internalMove, isTrue);
      // 目标持仓快照不应被买入腿二次累加（持仓由调用方创建时已初始化）。
      expect((await dao.getHolding(etf))!.quantity, 800);
    });
  });

  group('recordHistorical（补录历史流水）', () {
    test('backdated buy settles balances like an ordinary record', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 1000, costPrice: 1000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1.2,
      );

      final r = await service.recordHistorical(
        accountId: acc,
        holdingId: fund,
        type: TransactionType.buy,
        quantity: 100,
        price: 1.0,
        amount: 100,
        cashSourceId: cash,
        occurredAt: DateTime(2026, 1, 5),
      );
      expect(r.ok, isTrue, reason: r.message);

      // 补录也会实时结算余额：现金来源扣款、目标持仓加仓，
      // 与普通 record 完全一致（不再"只记流水不动快照"）。
      expect((await dao.getHolding(cash))!.quantity, 900,
          reason: '补录买入后现金余额应扣减：1000 - 100 = 900');
      expect((await dao.getHolding(fund))!.quantity, 100,
          reason: '补录买入后目标持仓数量应增加');
      final txns = await dao.getTransactions();
      expect(txns, hasLength(1));
      expect(txns.single.type, TransactionType.buy.storageName);
      expect(txns.single.occurredAt, DateTime(2026, 1, 5));
      expect(txns.single.cashSourceId, cash);
    });

    test('backdated buy from drained source is rejected (balance >= 0)',
        () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '余额宝', type: AssetType.bankDeposit,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      final bond = await addHolding(
        accountId: acc, name: '债券', type: AssetType.bond,
        quantity: 43386.91, costPrice: 1.1524, latestPrice: 1.1551,
      );

      final r = await service.recordHistorical(
        accountId: acc,
        holdingId: bond,
        type: TransactionType.buy,
        quantity: 43386.91,
        price: 1.1524,
        amount: 49999.08,
        cashSourceId: cash,
        occurredAt: DateTime(2026, 9, 2),
      );
      // 资产类账户余额不能为负：当前余额 0 无法出资，补录理应被拒。
      expect(r.ok, isFalse,
          reason: '余额为 0 的来源不能补录买入（资产账户不允许为负）');
      expect(r.message, contains('余额不足'));
      expect((await dao.getHolding(cash))!.quantity, 0);
      expect(await dao.getTransactions(), isEmpty);
    });

    test('backdated transfer settles both sides', () async {
      final acc = await addAccount('A');
      final from = await addHolding(
        accountId: acc, name: '现金A', type: AssetType.cash,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final to = await addHolding(
        accountId: acc, name: '现金B', type: AssetType.cash,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );

      final r = await service.recordHistorical(
        accountId: acc,
        type: TransactionType.transferIn,
        amount: 2000,
        cashSourceId: from,
        cashTargetId: to,
        occurredAt: DateTime(2026, 2, 10),
      );
      expect(r.ok, isTrue, reason: r.message);
      expect((await dao.getHolding(from))!.quantity, 3000,
          reason: '转账后来源余额应扣减：5000 - 2000 = 3000');
      expect((await dao.getHolding(to))!.quantity, 2000,
          reason: '转账后目标余额应增加：0 + 2000 = 2000');
      final txns = await dao.getTransactions();
      expect(txns, hasLength(1));
      expect(txns.single.type, TransactionType.transferIn.storageName);
    });

    test('rejects future-dated entries', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 1000, costPrice: 1000, latestPrice: 1,
      );
      final r = await service.recordHistorical(
        accountId: acc,
        type: TransactionType.income,
        amount: 100,
        cashTargetId: cash,
        occurredAt: DateTime.now().add(const Duration(days: 1)),
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('不能晚于今天'));
    });
  });

  group('deleteHolding（删除持仓连带配对赎回腿）', () {
    test('deleting redeem-to-create target removes both legs', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '余额宝', type: AssetType.bankDeposit,
        quantity: 200000, costPrice: 200000, latestPrice: 1,
      );
      final etf = await addHolding(
        accountId: acc, name: '十年国债ETF', type: AssetType.etf,
        quantity: 300, costPrice: 134.798, latestPrice: 134.725,
        symbol: 'sh511260',
      );
      // 赎回购买：写双腿（sell 余额宝 + buy ETF）。
      final r = await service.recordRedemption(
        sourceHoldingId: cash,
        amount: 40439.4,
        currency: 'CNY',
        occurredAt: DateTime(2026, 9, 21),
        note: '赎回购买 十年国债ETF',
        targetHoldingId: etf,
        targetQuantity: 300,
        targetPrice: 134.798,
      );
      expect(r.ok, isTrue, reason: r.message);
      expect(await dao.getTransactions(), hasLength(2));

      // 删除目标持仓：配对的两条腿都应被清理，余额宝不再残留卖出腿。
      await dao.deleteHolding(etf);
      expect(await dao.getHolding(etf), null,
          reason: '持仓应被删除');
      final left = await dao.getTransactions();
      expect(left, isEmpty,
          reason: '删除目标持仓应连带删除配对的赎回卖出腿，防止残留孤儿流水');
    });
  });

  group('组合交易序列健壮性（余额/成本/收益不漂移）', () {
    /// 校验所有现金类余额 >= 0（资产账户不允许为负）。
    Future<void> expectNoNegativeCash() async {
      for (final h in await dao.getHoldings()) {
        final t = AssetType.fromStorage(h.assetType);
        if (!t.isAmountBased) continue;
        expect(h.quantity, greaterThanOrEqualTo(-1e-6),
            reason: '「${h.name}」现金余额被扣成负数：${h.quantity}');
      }
    }

    test('卖出→现金→再买入循环 N 次，总成本不虚增', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 100000, costPrice: 100000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1.0,
      );

      final startCost = await portfolioCost();
      var cashBal = 100000.0;
      var fundQty = 0.0;
      var when = DateTime(2026, 9, 10, 10, 0, 0); // 错开时间避免 UNIQUE 时间冲突
      for (var i = 0; i < 3; i++) {
        // 现金买基金 10,000
        final buy = await service.record(
          accountId: acc, holdingId: fund, type: TransactionType.buy,
          quantity: 10000, price: 1.0, amount: 10000,
          cashSourceId: cash, occurredAt: when,
        );
        expect(buy.ok, isTrue, reason: 'loop $i buy: ${buy.message}');
        cashBal -= 10000;
        fundQty += 10000;
        when = when.add(const Duration(minutes: 1));
        // 全卖回款到现金
        final sell = await service.record(
          accountId: acc, holdingId: fund, type: TransactionType.sell,
          quantity: fundQty, price: 1.0, amount: fundQty,
          cashTargetId: cash, occurredAt: when,
        );
        expect(sell.ok, isTrue, reason: 'loop $i sell: ${sell.message}');
        cashBal += fundQty;
        fundQty = 0;
        when = when.add(const Duration(minutes: 1));
      }
      // 现金余额应精确回落到初始值
      expect((await dao.getHolding(cash))!.quantity, closeTo(100000, 1e-6),
          reason: '买→卖→回款循环后现金余额应不变');
      // 总成本守恒：所有循环都是内部移动，成本不应变化
      expect(await portfolioCost(), closeTo(startCost, 1e-3),
          reason: '卖出→现金→再买入循环后组合总成本应守恒');
      await expectNoNegativeCash();
    });

    test('多类型连续交易：买入/卖出/转账/分红后余额与成本对账', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 50000, costPrice: 50000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 2.0,
      );
      final other = await addHolding(
        accountId: acc, name: '活期', type: AssetType.liquidWealth,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );

      final startCost = await portfolioCost();
      var when = DateTime(2026, 9, 10, 10, 0, 0);
      // 现金买入基金 20,000
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 10000, price: 2.0, amount: 20000, cashSourceId: cash,
        occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 现金账户 → 活期 转账 5,000
      await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 5000, cashSourceId: cash, cashTargetId: other, occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 基金分红 1,000 入现金（成本法扣单位成本）
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.dividend,
        amount: 1000, cashTargetId: cash, occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 卖出基金 5,000 份回款现金
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.sell,
        quantity: 5000, price: 2.0, amount: 10000, cashTargetId: cash,
        occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 活期 → 现金 转账 2,000
      await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 2000, cashSourceId: other, cashTargetId: cash, occurredAt: when,
      );

      // 现金余额 = 50000 - 20000(买) + 1000(分红) + 10000(卖回) + 2000(活期转回)
      //            - 5000(转出)
      final cashH = (await dao.getHolding(cash))!;
      expect(cashH.quantity, closeTo(38000, 1e-6),
          reason: '多笔交易后现金余额应按流水精确结算，实际：${cashH.quantity}');
      // 基金 剩余 5,000 份
      expect((await dao.getHolding(fund))!.quantity, closeTo(5000, 1e-6));
      // 活期收到 5000 转出 2000 = 3000
      expect((await dao.getHolding(other))!.quantity, closeTo(3000, 1e-6));
      // 总成本：内转/买卖不改变；分红成本法把 1,000 从基金成本移出（收益落袋）。
      expect(await portfolioCost(), closeTo(startCost - 1000, 1e-3),
          reason: '内部转账/买卖不改变总成本，分红收回本金再从总成本扣除');
      await expectNoNegativeCash();
    });

    test('删除序列中间一笔流水后，后续账户状态正确回滚', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 10000, costPrice: 10000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1.0,
      );

      // 现金买基金 4,000
      final b1 = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 4000, price: 1.0, amount: 4000, cashSourceId: cash,
        occurredAt: DateTime(2026, 9, 10, 10, 0, 0),
      );
      expect(b1.ok, isTrue);
      // 再买 6,000（现金总额 10,000 全花光）
      final b2 = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 6000, price: 1.0, amount: 6000, cashSourceId: cash,
        occurredAt: DateTime(2026, 9, 10, 10, 1, 0),
      );
      expect(b2.ok, isTrue);
      // 删除最后一笔买入（移动平均只能逆序撤销）：现金应回滚 +6000，
      // 基金应回滚 -6000 份，留下 4,000 份与首笔买入对应的状态。
      final txns = await dao.getTransactions();
      final rm = await service.remove(txns.last.id);
      expect(rm.ok, isTrue, reason: rm.message);
      expect((await dao.getHolding(cash))!.quantity, closeTo(6000, 1e-6),
          reason: '删除买入后现金余额应回滚 10000-4000=6000');
      expect((await dao.getHolding(fund))!.quantity, closeTo(4000, 1e-6),
          reason: '删除买入后基金应剩 4000 份');
      await expectNoNegativeCash();
    });

    test('补录历史买入 + 今天流水叠加后余额一致', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 20000, costPrice: 20000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1.0,
      );

      // 补录历史买入 5,000（发生在过去）
      final hist = await service.recordHistorical(
        accountId: acc,
        holdingId: fund,
        type: TransactionType.buy,
        quantity: 5000,
        price: 1.0,
        amount: 5000,
        cashSourceId: cash,
        occurredAt: DateTime(2025, 12, 31),
      );
      expect(hist.ok, isTrue, reason: hist.message);
      // 今天再买入 3,000
      final today = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 3000, price: 1.0, amount: 3000, cashSourceId: cash,
      );
      expect(today.ok, isTrue, reason: today.message);
      // 现金 = 20000 - 5000 - 3000 = 12000；基金 = 8000 份
      expect((await dao.getHolding(cash))!.quantity, closeTo(12000, 1e-6));
      expect((await dao.getHolding(fund))!.quantity, closeTo(8000, 1e-6));
      await expectNoNegativeCash();
    });
  });

  group('recordHoldingCreation（新建持仓初始化流水）', () {
    test('direct share holding creation writes a buy flow without double '
        'booking', () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 100, costPrice: 2.0, latestPrice: 2.0,
      );
      final r = await service.recordHoldingCreation(
        accountId: acc,
        holdingId: fund,
        type: AssetType.mutualFund,
        quantity: 100,
        price: 2.0,
        amount: 200,
        occurredAt: DateTime(2026, 9, 1),
      );
      expect(r.ok, isTrue, reason: r.message);
      final txns = await dao.getTransactions();
      expect(txns, hasLength(1));
      expect(txns.single.type, TransactionType.buy.storageName);
      expect(txns.single.holdingId, fund);
      expect(txns.single.amount, closeTo(200, 1e-6));
      // 持仓快照不应被双算（创建时已写入数量/成本）。
      expect((await dao.getHolding(fund))!.quantity, 100);
      expect((await dao.getHolding(fund))!.costPrice, 2.0);
    });

    test('cash account creation writes an income flow', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      final r = await service.recordHoldingCreation(
        accountId: acc,
        holdingId: cash,
        type: AssetType.cash,
        quantity: 5000,
        amount: 5000,
        occurredAt: DateTime(2026, 8, 1),
      );
      expect(r.ok, isTrue, reason: r.message);
      final txns = await dao.getTransactions();
      expect(txns, hasLength(1));
      expect(txns.single.type, TransactionType.income.storageName);
      expect(txns.single.amount, closeTo(5000, 1e-6));
    });

    test('liability creation writes a borrowing (transferOut) flow',
        () async {
      final acc = await addAccount('A');
      final card = await addHolding(
        accountId: acc, name: '信用卡', type: AssetType.liability,
        quantity: 3000, costPrice: 3000, latestPrice: 1,
      );
      final r = await service.recordHoldingCreation(
        accountId: acc,
        holdingId: card,
        type: AssetType.liability,
        quantity: 3000,
        amount: 3000,
        occurredAt: DateTime(2026, 8, 1),
      );
      expect(r.ok, isTrue, reason: r.message);
      final txns = await dao.getTransactions();
      expect(txns, hasLength(1));
      expect(txns.single.type, TransactionType.transferOut.storageName,
          reason: '负债初始化 = 借款（与还款 transferIn 对称）');
      expect(txns.single.holdingId, card);
    });

    test('zero-balance holding gets no init flow', () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '空基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      final r = await service.recordHoldingCreation(
        accountId: acc,
        holdingId: fund,
        type: AssetType.mutualFund,
        quantity: 0,
        amount: 0,
        occurredAt: DateTime(2026, 9, 1),
      );
      expect(r.ok, isTrue, reason: r.message);
      expect(await dao.getTransactions(), isEmpty);
    });

    test('liability consume and repayment both carry flows', () async {
      final acc = await addAccount('A');
      final card = await addHolding(
        accountId: acc, name: '信用卡', type: AssetType.liability,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 10000, costPrice: 10000, latestPrice: 1,
      );
      // 新建信用卡
      await service.recordHoldingCreation(
        accountId: acc, holdingId: card, type: AssetType.liability,
        quantity: 0, amount: 0, occurredAt: DateTime(2026, 8, 1),
      );
      // 消费 500（负债增加）
      final consume = await service.record(
        accountId: acc, holdingId: card, type: TransactionType.consume,
        amount: 500, occurredAt: DateTime(2026, 8, 2),
      );
      expect(consume.ok, isTrue, reason: consume.message);
      expect((await dao.getHolding(card))!.quantity, closeTo(500, 1e-6),
          reason: '消费后负债余额增加');
      // 还款 200（现金 → 负债）
      final repay = await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 200, cashSourceId: cash, cashTargetId: card,
        occurredAt: DateTime(2026, 8, 3),
      );
      expect(repay.ok, isTrue, reason: repay.message);
      expect((await dao.getHolding(card))!.quantity, closeTo(300, 1e-6),
          reason: '还款后负债余额减少');
      expect((await dao.getHolding(cash))!.quantity, closeTo(9800, 1e-6));
      // 每条操作都应对应有流水：创建(0-balance→无) + 消费 + 还款 = 2
      expect(await dao.getTransactions(), hasLength(2));
    });

    test('跨类型全序列：买→卖部分→分红→拆分→再买，余额/成本/收益守恒',
        () async {
      Future<void> expectNoNegativeCash() async {
        for (final h in await dao.getHoldings()) {
          final t = AssetType.fromStorage(h.assetType);
          if (!t.isAmountBased) continue;
          expect(h.quantity, greaterThanOrEqualTo(-1e-6),
              reason: '「${h.name}」现金余额被扣成负数：${h.quantity}');
        }
      }
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 50000, costPrice: 50000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1.0,
      );
      // 起点成本
      final startCost = await portfolioCost();
      var when = DateTime(2026, 9, 10, 9, 0, 0);

      // 1) 现金买基金 10,000 份 @1.0
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 10000, price: 1.0, amount: 10000, cashSourceId: cash,
        occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 2) 卖出 3,000 份 @1.5 回款现金
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.sell,
        quantity: 3000, price: 1.5, amount: 4500, cashTargetId: cash,
        occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 3) 分红 1,000 入现金（成本法扣单位成本）
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.dividend,
        amount: 1000, cashTargetId: cash, occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 4) 1:2 拆分（7,000 → 14,000 份，单位成本减半）
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.split,
        amount: 2, occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 5) 再买 2,000 份 @0.6（拆分后价格）
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 2000, price: 0.6, amount: 1200, cashSourceId: cash,
        occurredAt: when,
      );

      // 现金：50000 -10000(买) +4500(卖回) +1000(分红) -1200(再买)
      expect((await dao.getHolding(cash))!.quantity, closeTo(44300, 1e-6),
          reason: '全序列后现金余额应精确结算');
      // 基金：卖出后 7000 → 拆分 14000 → 再买 2000 = 16000
      expect((await dao.getHolding(fund))!.quantity, closeTo(16000, 1e-6));
      // 总成本：分红 1000 从基金成本移出（成本法），其余内部移动守恒
      expect(await portfolioCost(), closeTo(startCost - 1000, 1e-3),
          reason: '跨类型序列后总成本仅因分红成本法减少 1000');
      await expectNoNegativeCash();
    });

    test('卖出部分（非全额）回款：单位成本保留，成本守恒', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 10000, costPrice: 10000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 2.0,
      );
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 5000, price: 2.0, amount: 10000, cashSourceId: cash,
        occurredAt: DateTime(2026, 9, 1),
      );
      // 卖 2,000 份 @2.5 回款
      final sell = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.sell,
        quantity: 2000, price: 2.5, amount: 5000, cashTargetId: cash,
        occurredAt: DateTime(2026, 9, 2),
      );
      expect(sell.ok, isTrue, reason: sell.message);
      final f = (await dao.getHolding(fund))!;
      expect(f.quantity, closeTo(3000, 1e-6));
      expect(f.costPrice, closeTo(2.0, 1e-6),
          reason: '部分卖出保留单位成本（移动平均不变）');
      // 现金 = 10000 - 10000 + 5000 = 5000
      expect((await dao.getHolding(cash))!.quantity, closeTo(5000, 1e-6));
      // 总成本守恒：未实现收益留在基金，总成本不变
      expect(await portfolioCost(), closeTo(10000, 1e-3));
    });

    test('负债完整生命周期：借款→消费→还款→清空', () async {
      final acc = await addAccount('A');
      final card = await addHolding(
        accountId: acc, name: '信用卡', type: AssetType.liability,
        quantity: 0, costPrice: 0, latestPrice: 1,
      );
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 5000, costPrice: 5000, latestPrice: 1,
      );
      var when = DateTime(2026, 9, 1, 9, 0, 0);
      // 借款 1000（负债 → 现金：负债增加）
      await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 1000, cashSourceId: card, cashTargetId: cash,
        occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 消费 800（负债 +800）
      await service.record(
        accountId: acc, holdingId: card, type: TransactionType.consume,
        amount: 800, occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 还款 1500（现金 → 负债：负债减少 1500）
      await service.record(
        accountId: acc, type: TransactionType.transferOut,
        amount: 1500, cashSourceId: cash, cashTargetId: card,
        occurredAt: when,
      );
      // 负债 = 1000 + 800 - 1500 = 300
      expect((await dao.getHolding(card))!.quantity, closeTo(300, 1e-6),
          reason: '负债余额 = 借款+消费-还款 = 300');
      // 现金 = 5000 +1000(借款) -1500(还款) = 4500
      expect((await dao.getHolding(cash))!.quantity, closeTo(4500, 1e-6));
      // 还款到负债是内部移动，组合成本应守恒（负债成本随余额走）
      for (final h in await dao.getHoldings()) {
        final t = AssetType.fromStorage(h.assetType);
        if (t.isAmountBased) {
          expect(h.quantity, greaterThanOrEqualTo(-1e-6));
        }
      }
    });

    test('删除「回款不入账」的卖出（无 target）：无副作用回滚', () async {
      final acc = await addAccount('A');
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 500, costPrice: 2.0, latestPrice: 2.5,
      );
      final sell = await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.sell,
        quantity: 200, price: 2.5, amount: 500,
        occurredAt: DateTime(2026, 9, 1), // 无 cashTargetId = 回款不入账
      );
      expect(sell.ok, isTrue, reason: sell.message);
      expect((await dao.getHolding(fund))!.quantity, closeTo(300, 1e-6));
      final rm = await service.remove(
          (await dao.getTransactions()).single.id);
      expect(rm.ok, isTrue, reason: rm.message);
      expect((await dao.getHolding(fund))!.quantity, closeTo(500, 1e-6),
          reason: '删除无入账卖出应恢复份额');
      expect(await dao.getTransactions(), isEmpty);
    });

    test('拆分后买卖：基于新比例正确记账', () async {
      final acc = await addAccount('A');
      final cash = await addHolding(
        accountId: acc, name: '现金', type: AssetType.cash,
        quantity: 10000, costPrice: 10000, latestPrice: 1,
      );
      final fund = await addHolding(
        accountId: acc, name: '基金', type: AssetType.mutualFund,
        quantity: 0, costPrice: 0, latestPrice: 1.0,
      );
      var when = DateTime(2026, 9, 1, 9, 0, 0);
      // 买 1,000 份 @1.0
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.buy,
        quantity: 1000, price: 1.0, amount: 1000, cashSourceId: cash,
        occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 1:10 拆分
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.split,
        amount: 10, occurredAt: when,
      );
      when = when.add(const Duration(minutes: 1));
      // 拆分后卖 3,000 份（剩 7,000）
      await service.record(
        accountId: acc, holdingId: fund, type: TransactionType.sell,
        quantity: 3000, price: 0.1, amount: 300, cashTargetId: cash,
        occurredAt: when,
      );
      final f = (await dao.getHolding(fund))!;
      expect(f.quantity, closeTo(7000, 1e-6),
          reason: '拆分后份额按新比例');
      expect(f.costPrice, closeTo(0.1, 1e-6),
          reason: '拆分后单位成本 = 1.0/10 = 0.1');
      // 现金 = 10000 -1000 +300 = 9300
      expect((await dao.getHolding(cash))!.quantity, closeTo(9300, 1e-6));
      expect((await dao.getHolding(cash))!.quantity,
          greaterThanOrEqualTo(-1e-6));
    });
  });
}
