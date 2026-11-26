import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/core/history_sync.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/transaction_service.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AssetDao dao;
  late TransactionService service;
  late int account;

  setUp(() async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    dao = AssetDao(db);
    service = TransactionService(dao);
    account = await dao.createAccount(
      AccountsCompanion.insert(name: '账户', type: 'general'),
    );
  });

  Future<int> holding(
    String name,
    AssetType type,
    double quantity,
    double cost,
    double price,
  ) => dao.createHolding(
    HoldingsCompanion.insert(
      accountId: account,
      name: name,
      assetType: type.storageName,
      quantity: Value(quantity),
      costPrice: Value(cost),
      latestPrice: Value(price),
    ),
  );

  Future<({int cash, int etf, TransactionRow trade, TransactionRow buy})>
  closedPositionWithTransposedSale() async {
    final cash = await holding('现金', AssetType.cash, 1000, 1000, 1);
    final etf = await holding('ETF', AssetType.etf, 0, 0, 2);
    for (final trade in [
      (TransactionType.buy, 20.0, 2.0, 40.0),
      (TransactionType.sell, 1.5, 10.0, 15.0),
      (TransactionType.sell, 6.0, 2.0, 12.0),
      (TransactionType.sell, 4.0, 2.0, 8.0),
    ].indexed) {
      final (type, quantity, price, amount) = trade.$2;
      final result = await service.record(
        accountId: account,
        holdingId: etf,
        type: type,
        quantity: quantity,
        price: price,
        amount: amount,
        cashSourceId: type == TransactionType.buy ? cash : null,
        cashTargetId: type == TransactionType.sell ? cash : null,
        occurredAt: DateTime(2026, 7, 1 + trade.$1, 12),
      );
      expect(result.ok, isTrue, reason: result.message);
    }
    final stock = (await dao.getHolding(etf))!;
    expect(stock.quantity, 8.5);
    await dao.updateHolding(stock.copyWith(quantity: 0));
    final rows = await dao.getTransactions();
    return (cash: cash, etf: etf, trade: rows[1], buy: rows.first);
  }

  test(
    'closed position corrects transposed sale and all subsequent principal atomically',
    () async {
      final fixture = await closedPositionWithTransposedSale();
      final originalRows = await dao.getTransactions();
      final originalHoldings = await dao.getHoldings();
      final preview = await service.previewCorrection(
        fixture.trade,
        amount: 15,
        quantity: 10,
        price: 1.5,
      );
      expect(preview.reconciledClosedQuantity, 8.5);
      expect(preview.replayedRows, 3);
      expect(preview.usesSnapshotPrincipal, isFalse);
      expect(await dao.getTransactions(), originalRows);
      expect(await dao.getHoldings(), originalHoldings);
      expect(await dao.getSetting(historySyncDirtyKey), isNull);
      final cashImpact = preview.holdings.singleWhere(
        (v) => v.before.id == fixture.cash,
      );
      expect(cashImpact.before.quantity, 995);
      expect(cashImpact.after.quantity, 995);
      expect(cashImpact.before.costPrice, 983);
      expect(cashImpact.after.costPrice, 1000);
      final result = await service.saveCorrection(preview);
      expect(result.ok, isTrue, reason: result.message);
      final rows = await dao.getTransactions();
      expect(rows.map((r) => r.id), originalRows.map((r) => r.id));
      expect(rows.map((r) => r.amount), originalRows.map((r) => r.amount));
      expect(
        rows.map((r) => r.occurredAt),
        originalRows.map((r) => r.occurredAt),
      );
      expect(
        rows.map((r) => r.recordedAtMicros),
        originalRows.map((r) => r.recordedAtMicros),
      );
      expect(rows.skip(1).map((r) => r.costMovedAmount), [20, 12, 8]);
      expect(rows[1].quantity, 10);
      expect(rows[1].price, 1.5);
      expect((await dao.getHolding(fixture.etf))!.quantity, 0);
      expect((await dao.getHolding(fixture.cash))!.quantity, 995);
      expect((await dao.getHolding(fixture.cash))!.costPrice, 1000);
      expect(await dao.getSetting(historySyncDirtyKey), historyDirtySet);
      expect(await dao.getSetting(historyFullRebuildKey), '1');
    },
  );

  test(
    'closed-position save rechecks earlier purchase evidence outside the replay window',
    () async {
      final fixture = await closedPositionWithTransposedSale();
      final preview = await service.previewCorrection(
        fixture.trade,
        amount: 15,
        quantity: 10,
        price: 1.5,
      );
      await dao.updateTransaction(
        fixture.buy.copyWith(note: const Value('更正说明')),
      );
      final rows = await dao.getTransactions();
      final holdings = await dao.getHoldings();
      final result = await service.saveCorrection(preview);
      expect(result.ok, isFalse);
      expect(result.message, contains('重新预览'));
      expect(await dao.getTransactions(), rows);
      expect(await dao.getHoldings(), holdings);
      expect(await dao.getSetting(historySyncDirtyKey), isNull);
    },
  );

  test(
    'missing legacy purchase cost requires snapshot evidence, also rechecked on save',
    () async {
      final fixture = await closedPositionWithTransposedSale();
      await dao.updateTransaction(
        fixture.buy.copyWith(costMovedAmount: const Value(null)),
      );
      final legacy = (await dao.getTransactions()).first;
      final baseline = await dao.getHoldings();
      await expectLater(
        service.previewCorrection(
          fixture.trade,
          amount: 15,
          quantity: 10,
          price: 1.5,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(await dao.getHoldings(), baseline);
      final created = DateTime.now().add(const Duration(seconds: 10));
      SnapshotRow snapshot(String date, double cashCost, double stockCost) =>
          SnapshotRow(
            date: date,
            currency: 'CNY',
            totalValue: cashCost + stockCost,
            totalCost: cashCost + stockCost,
            liabilities: 0,
            createdAt: created,
            holdingValues: encodeHoldingValues([
              DayHoldingValue(
                holdingId: fixture.cash,
                name: '现金',
                type: AssetType.cash,
                value: cashCost,
                cost: cashCost,
                liability: false,
              ),
              DayHoldingValue(
                holdingId: fixture.etf,
                name: 'ETF',
                type: AssetType.etf,
                value: stockCost,
                cost: stockCost,
                liability: false,
              ),
            ]),
          );
      await dao.upsertSnapshot(
        snapshot('2026-06-30', 1000, 0).toCompanion(true),
      );
      final closing = snapshot('2026-07-01', 960, 40);
      await dao.upsertSnapshot(closing.toCompanion(true));
      final preview = await service.previewCorrection(
        fixture.trade,
        amount: 15,
        quantity: 10,
        price: 1.5,
      );
      expect(preview.reconciledClosedQuantity, 8.5);
      expect(await dao.getTransaction(legacy.id), legacy);
      expect(preview.usesSnapshotPrincipal, isTrue);
      await dao.upsertSnapshot(
        closing
            .copyWith(createdAt: created.add(const Duration(seconds: 1)))
            .toCompanion(true),
      );
      final rows = await dao.getTransactions();
      final holdings = await dao.getHoldings();
      final result = await service.saveCorrection(preview);
      expect(result.ok, isFalse);
      expect(result.message, contains('重新预览'));
      expect(await dao.getTransactions(), rows);
      expect(await dao.getHoldings(), holdings);
    },
  );

  for (final error in [
    'missing purchase',
    'split',
    'different amount',
    'not transposed',
    'wrong original cost',
  ]) {
    test(
      'closed-position reconciliation rejects $error without ledger writes',
      () async {
        final fixture = await closedPositionWithTransposedSale();
        if (error == 'missing purchase') {
          await dao.deleteTransaction(fixture.buy.id);
        }
        if (error == 'split') {
          await dao.createTransaction(
            TransactionsCompanion.insert(
              accountId: account,
              holdingId: Value(fixture.etf),
              type: 'split',
              amount: 2,
              occurredAt: DateTime(2026, 7, 5),
            ),
          );
        }
        if (error == 'wrong original cost') {
          await dao.updateHolding(
            (await dao.getHolding(fixture.etf))!.copyWith(costPrice: 3),
          );
        }
        final rows = await dao.getTransactions();
        final holdings = await dao.getHoldings();
        await expectLater(
          service.previewCorrection(
            fixture.trade,
            amount: error == 'different amount' ? 16 : 15,
            quantity: error == 'not transposed' ? 11 : 10,
            price: 1.5,
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(await dao.getTransactions(), rows);
        expect(await dao.getHoldings(), holdings);
        expect(await dao.getSetting(historySyncDirtyKey), isNull);
        expect(await dao.getSetting(historyFullRebuildKey), isNull);
      },
    );
  }

  test(
    'preview is read-only, then corrects an older buy and replays the cash and sell',
    () async {
      final cash = await holding('现金', AssetType.cash, 1000, 1000, 1);
      final etf = await holding('ETF', AssetType.etf, 100, 10, 11);
      final when = DateTime(2026, 2, 1, 9);
      expect(
        (await service.record(
          accountId: account,
          holdingId: etf,
          type: TransactionType.buy,
          amount: 100,
          quantity: 10,
          price: 10,
          occurredAt: when,
          cashSourceId: cash,
        )).ok,
        isTrue,
      );
      final buy = (await dao.getTransactions()).single;
      expect(
        (await service.record(
          accountId: account,
          holdingId: etf,
          type: TransactionType.sell,
          amount: 60,
          quantity: 5,
          price: 12,
          occurredAt: when.add(const Duration(days: 1)),
          cashTargetId: cash,
        )).ok,
        isTrue,
      );
      final originalRows = await dao.getTransactions();
      final originalHoldings = await dao.getHoldings();
      final snapshotDay = todayKey();
      await dao.upsertSnapshot(
        SnapshotsCompanion.insert(
          date: snapshotDay,
          totalValue: 2115,
          totalCost: 2000,
          holdingValues: Value(
            encodeHoldingValues([
              DayHoldingValue(
                holdingId: etf,
                name: 'ETF',
                type: AssetType.etf,
                value: 1155,
                cost: 1050,
                liability: false,
              ),
              DayHoldingValue(
                holdingId: cash,
                name: '现金',
                type: AssetType.cash,
                value: 960,
                cost: 950,
                liability: false,
              ),
            ]),
          ),
          createdAt: Value(DateTime.now().add(const Duration(seconds: 5))),
        ),
      );
      final preview = await service.previewCorrection(
        buy,
        amount: 240,
        quantity: 20,
        price: 12,
      );
      final cashChange = preview.holdings.singleWhere(
        (impact) => impact.before.id == cash,
      );
      expect(cashChange.before.quantity, 960);
      expect(cashChange.after.quantity, 820);
      expect(preview.replayedRows, 2);
      expect(preview.historyFrom, when);
      expect(preview.historicalGain?.date, snapshotDay);
      expect(preview.historicalGain?.before, 115);
      expect(preview.historicalGain?.after, closeTo(85, 1e-8));
      expect(await dao.getTransactions(), originalRows);
      expect(await dao.getHoldings(), originalHoldings);
      expect(await dao.getSetting(historySyncDirtyKey), isNull);

      final result = await service.saveCorrection(preview);
      expect(result.message, isNull);
      expect(result.ok, isTrue);
      final rows = await dao.getTransactions();
      expect(rows.map((row) => row.id), originalRows.map((row) => row.id));
      expect(rows.first.quantity, 20);
      expect(rows.first.price, 12);
      expect(rows.first.amount, 240);
      expect(rows.first.recordedAtMicros, buy.recordedAtMicros);
      expect(rows.last.costMovedAmount, closeTo(5 * 1240 / 120, 1e-8));
      expect((await dao.getHolding(etf))!.quantity, 115);
      expect((await dao.getHolding(cash))!.quantity, 820);
      expect(await dao.getSetting(historySyncDirtyKey), historyDirtySet);
      expect(await dao.getSetting(historyFullRebuildKey), '1');
    },
  );

  test('an impossible later sale rejects the entire correction', () async {
    final etf = await holding('ETF', AssetType.etf, 0, 0, 11);
    expect(
      (await service.record(
        accountId: account,
        holdingId: etf,
        type: TransactionType.buy,
        amount: 100,
        quantity: 10,
        price: 10,
      )).ok,
      isTrue,
    );
    final buy = (await dao.getTransactions()).single;
    expect(
      (await service.record(
        accountId: account,
        holdingId: etf,
        type: TransactionType.sell,
        amount: 96,
        quantity: 8,
        price: 12,
      )).ok,
      isTrue,
    );
    final originalRows = await dao.getTransactions();
    await expectLater(
      service.previewCorrection(buy, amount: 50, quantity: 5, price: 10),
      throwsA(isA<ArgumentError>()),
    );
    expect(await dao.getTransactions(), originalRows);
    expect((await dao.getHolding(etf))!.quantity, 2);
  });

  test(
    'changing a paired purchase corrects its linked redemption in place',
    () async {
      final source = await holding('原基金', AssetType.mutualFund, 100, 8, 10);
      final target = await holding('新基金', AssetType.mutualFund, 10, 5, 10);
      expect(
        (await service.recordBuyFundedByHolding(
          sourceHoldingId: source,
          targetHoldingId: target,
          targetQuantity: 20,
          targetPrice: 10,
          amount: 200,
        )).ok,
        isTrue,
      );
      final original = await dao.getTransactions();
      final preview = await service.previewCorrection(
        original.last,
        amount: 300,
        quantity: 30,
        price: 10,
      );
      final result = await service.saveCorrection(preview);
      expect(result.message, isNull);
      expect(result.ok, isTrue);
      final corrected = await dao.getTransactions();
      expect(corrected.map((row) => row.id), original.map((row) => row.id));
      expect(corrected.map((row) => row.amount), [300, 300]);
      expect(corrected.map((row) => row.quantity), [30, 30]);
      expect(corrected.map((row) => row.costMovedAmount), [240, 240]);
      expect(corrected.last.redemptionGroup, original.last.redemptionGroup);
      expect((await dao.getHolding(source))!.quantity, 70);
      expect((await dao.getHolding(target))!.quantity, 40);
    },
  );

  test(
    'save rejects a preview when a linked position changes meanwhile',
    () async {
      final etf = await holding('ETF', AssetType.etf, 0, 0, 11);
      expect(
        (await service.record(
          accountId: account,
          holdingId: etf,
          type: TransactionType.buy,
          amount: 100,
          quantity: 10,
          price: 10,
        )).ok,
        isTrue,
      );
      final buy = (await dao.getTransactions()).single;
      final preview = await service.previewCorrection(
        buy,
        amount: 200,
        quantity: 20,
        price: 10,
      );
      expect(
        (await service.record(
          accountId: account,
          holdingId: etf,
          type: TransactionType.sell,
          amount: 12,
          quantity: 1,
          price: 12,
        )).ok,
        isTrue,
      );
      final result = await service.saveCorrection(preview);
      expect(result.ok, isFalse);
      expect(result.message, contains('请重新预览'));
      expect(await dao.getTransaction(buy.id), buy);
      expect((await dao.getHolding(etf))!.quantity, 9);
    },
  );
}
