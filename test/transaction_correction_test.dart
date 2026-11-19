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
