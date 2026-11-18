import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/components/transaction_details.dart';
import 'package:drift/drift.dart' show Value;
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
}
