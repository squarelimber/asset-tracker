import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/transaction_service.dart';
import 'package:asset_tracker/ui/components/transaction_details.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TransactionRow transaction({
    String type = 'buy',
    double? price = 2.1234,
    double? quantity = 12,
  }) => TransactionRow(
    id: 1,
    accountId: 1,
    holdingId: 1,
    type: type,
    price: price,
    quantity: quantity,
    amount: 25.48,
    currency: 'CNY',
    occurredAt: DateTime(2026, 11, 17, 12, 30),
    note: '测试备注',
    costMoved: false,
    internalMove: false,
    updatedAt: DateTime(2026),
  );

  Future<void> open(
    WidgetTester tester,
    ProviderContainer container,
    TransactionRow txn, {
    Future<void> Function()? onEditDate,
  }) async {
    container.read(hideAmountsProvider.notifier).state = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTransactionDetails(
                  context,
                  txn,
                  onEditDate: onEditDate,
                ),
                child: const Text('查看'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
  }

  ProviderContainer container({
    List<HoldingRow> holdings = const [],
    List<AccountRow> accounts = const [],
  }) => ProviderContainer(
    overrides: [
      holdingsProvider.overrideWith((ref) => Stream.value(holdings)),
      accountsProvider.overrideWith((ref) => Stream.value(accounts)),
    ],
  );

  HoldingRow holding(int id, int accountId, String name) => HoldingRow(
    id: id,
    accountId: accountId,
    name: name,
    assetType: 'savings',
    marketSource: 'manual',
    quantity: 100,
    costPrice: 1,
    latestPrice: 1,
    currency: 'CNY',
    archived: false,
    costRecorded: true,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  AccountRow account(int id, String name) => AccountRow(
    id: id,
    name: name,
    type: 'bank',
    currency: 'CNY',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  testWidgets('详情显示成交信息、备注和完整时间，并实时遵循金额遮罩', (tester) async {
    final c = container();
    addTearDown(c.dispose);
    await open(tester, c, transaction());
    expect(find.text('交易详情'), findsOneWidget);
    expect(find.text('2.1234'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('¥25.48'), findsOneWidget);
    expect(find.text('测试备注'), findsOneWidget);
    expect(find.text('2026-11-17 12:30'), findsOneWidget);
    c.read(hideAmountsProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(find.text('****'), findsNWidgets(3));
    expect(find.text('2.1234'), findsNothing);
    expect(find.text('¥25.48'), findsNothing);
  });

  testWidgets('份额折算显示比例且不猜测缺失字段，日期按钮执行原回调', (tester) async {
    final c = container();
    addTearDown(c.dispose);
    var edited = false;
    await open(
      tester,
      c,
      transaction(type: 'split', price: null, quantity: null),
      onEditDate: () async {
        edited = true;
      },
    );
    expect(find.text('折算比例'), findsOneWidget);
    expect(find.text('×25.48'), findsOneWidget);
    expect(find.text('成交价'), findsNothing);
    expect(find.text('金额'), findsNothing);
    c.read(hideAmountsProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(find.text('×25.48'), findsNothing);
    await tester.tap(find.text('修改日期'));
    await tester.pumpAndSettle();
    expect(edited, isTrue);
    expect(find.text('交易详情'), findsNothing);
  });

  testWidgets('金额型持仓不展示合成的价格或数量', (tester) async {
    final c = container(holdings: [holding(1, 1, '活期')]);
    addTearDown(c.dispose);
    await open(tester, c, transaction(price: 1, quantity: 25.48));
    expect(find.text('活期'), findsOneWidget);
    expect(find.text('金额'), findsOneWidget);
    expect(find.text('¥25.48'), findsOneWidget);
    expect(find.text('成交价'), findsNothing);
    expect(find.text('数量'), findsNothing);
  });

  testWidgets('跨账户转账同时展示来源和去向及账户名称', (tester) async {
    final c = container(
      holdings: [holding(1, 1, '现金'), holding(2, 2, '现金')],
      accounts: [account(1, '甲账户'), account(2, '乙账户')],
    );
    addTearDown(c.dispose);
    await open(
      tester,
      c,
      transaction(
        type: 'transfer_out',
        price: null,
        quantity: null,
      ).copyWith(cashSourceId: const Value(1), cashTargetId: const Value(2)),
    );
    expect(find.text('来源'), findsOneWidget);
    expect(find.text('去向'), findsOneWidget);
    expect(find.text('甲账户 / 现金'), findsOneWidget);
    expect(find.text('乙账户 / 现金'), findsOneWidget);
  });

  testWidgets('清仓后份额与价格颠倒可预览、取消并确认更正', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    final accountId = await dao.createAccount(
      AccountsCompanion.insert(name: '账户', type: 'general'),
    );
    final cash = await dao.createHolding(
      HoldingsCompanion.insert(
        accountId: accountId,
        name: '现金',
        assetType: AssetType.cash.storageName,
        quantity: const Value(1000),
        costPrice: const Value(1000),
        costRecorded: const Value(true),
      ),
    );
    final stock = await dao.createHolding(
      HoldingsCompanion.insert(
        accountId: accountId,
        name: 'ETF',
        assetType: AssetType.etf.storageName,
        latestPrice: const Value(2),
      ),
    );
    final service = TransactionService(dao);
    for (final event in [
      (TransactionType.buy, 20.0, 2.0, 40.0),
      (TransactionType.sell, 1.5, 10.0, 15.0),
      (TransactionType.sell, 6.0, 2.0, 12.0),
      (TransactionType.sell, 4.0, 2.0, 8.0),
    ].indexed) {
      final (type, quantity, price, amount) = event.$2;
      expect(
        (await service.record(
          accountId: accountId,
          holdingId: stock,
          type: type,
          quantity: quantity,
          price: price,
          amount: amount,
          cashSourceId: type == TransactionType.buy ? cash : null,
          cashTargetId: type == TransactionType.sell ? cash : null,
          occurredAt: DateTime(2026, 7, event.$1 + 1),
        )).ok,
        isTrue,
      );
    }
    await dao.updateHolding(
      (await dao.getHolding(stock))!.copyWith(quantity: 0),
    );
    final rows = await dao.getTransactions();
    final before = await dao.getHoldings();
    final row = rows[1];
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        historySyncProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(c.dispose);
    await open(tester, c, row);
    Future<void> preview() async {
      await tester.tap(find.text('更正交易'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '10');
      await tester.enterText(find.byType(TextField).at(1), '1.5');
      await tester.ensureVisible(find.text('预览变更'));
      await tester.tap(find.text('预览变更'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1.5 份 × 10'), findsOneWidget);
      expect(find.textContaining('10 份 × 1.5'), findsOneWidget);
      expect(find.textContaining('当前持仓仍为 0'), findsOneWidget);
      expect(find.text('持仓份额 0 份 → 0 份'), findsOneWidget);
      expect(await dao.getTransactions(), rows);
      expect(await dao.getHoldings(), before);
      expect(tester.takeException(), isNull);
    }

    await preview();
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await dao.getTransactions(), rows);
    expect(await dao.getHoldings(), before);
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    await preview();
    await tester.ensureVisible(find.text('确认更正'));
    await tester.tap(find.text('确认更正'));
    await tester.pumpAndSettle();
    expect(find.text('交易已更正'), findsOneWidget);
    expect((await dao.getTransaction(row.id))!.quantity, 10);
    expect((await dao.getTransaction(row.id))!.price, 1.5);
    expect((await dao.getHolding(stock))!.quantity, 0);
    expect((await dao.getHolding(cash))!.quantity, 995);
  });

  testWidgets('详情可预览并确认更正原流水', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    final accountId = await dao.createAccount(
      AccountsCompanion.insert(name: '账户', type: 'general'),
    );
    final holdingId = await dao.createHolding(
      HoldingsCompanion.insert(
        accountId: accountId,
        name: '现金',
        assetType: 'cash',
        quantity: const Value(200),
        costPrice: const Value(200),
      ),
    );
    final service = TransactionService(dao);
    expect(
      (await service.record(
        accountId: accountId,
        holdingId: holdingId,
        type: TransactionType.income,
        amount: 100,
        cashTargetId: holdingId,
      )).ok,
      isTrue,
    );
    final row = (await dao.getTransactions()).single;
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        historySyncProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(c.dispose);
    await open(tester, c, row);
    await tester.tap(find.text('更正交易'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '150');
    await tester.tap(find.text('预览变更'));
    await tester.pumpAndSettle();
    expect(find.text('核对更正影响'), findsOneWidget);
    expect(find.text('余额 ¥300.00 → ¥350.00'), findsOneWidget);
    expect((await dao.getTransaction(row.id))!.amount, 100);
    await tester.ensureVisible(find.text('确认更正'));
    await tester.tap(find.text('确认更正'));
    await tester.pumpAndSettle();
    expect(find.text('交易已更正'), findsOneWidget);
    expect((await dao.getTransaction(row.id))!.amount, 150);
    expect((await dao.getHolding(holdingId))!.quantity, 350);
  });
}
