import 'package:drift/drift.dart' hide Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/transaction_service.dart';
import 'package:asset_tracker/ui/components/transaction_tile.dart';
import 'package:asset_tracker/ui/pages/transaction_dialogs.dart';
import 'package:asset_tracker/ui/pages/transactions/transactions_page.dart';

/// Host that opens the real per-holding transaction dialog.
class _TxnHost extends ConsumerWidget {
  const _TxnHost(this.holding);

  final HoldingRow holding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () =>
              showHoldingTransactionDialog(context, ref, holding),
          child: const Text('记一笔'),
        ),
      ),
    );
  }
}

void main() {
  test('record 支持指定发生日期（补录历史操作）', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    final accId = await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'));
    final hid = await dao.createHolding(HoldingsCompanion.insert(
      accountId: accId,
      name: '零钱',
      assetType: AssetType.cash.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(10000),
      costPrice: const Value(10000),
      latestPrice: const Value(1),
    ));
    final when = DateTime(2026, 9, 2, 15, 5, 28);
    final r = await TransactionService(dao).record(
      accountId: accId,
      holdingId: hid,
      type: TransactionType.expense,
      amount: 1225,
      cashTargetId: hid,
      occurredAt: when,
    );
    expect(r.ok, isTrue);
    final saved = (await dao.getTransactions()).single;
    expect(saved.occurredAt.year, 2026);
    expect(saved.occurredAt.month, 9);
    expect(saved.occurredAt.day, 2);
    expect(saved.occurredAt.hour, 15);
  });

  testWidgets('交易对话框提供「发生日期」，保存按所选日期落库并标脏',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final accId = await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accId,
      name: '零钱',
      assetType: AssetType.cash.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(10000),
      costPrice: const Value(10000),
      latestPrice: const Value(1),
    ));
    final holding = (await dao.getHoldings()).single;

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: _TxnHost(holding)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('记一笔'));
    await tester.pumpAndSettle();

    // 补录历史操作的能力：对话框必须暴露「发生日期」。
    expect(find.text('发生日期'), findsOneWidget,
        reason: '旧行为没有日期字段，补录历史操作只能记成今天');

    // 默认日期 = 今天；保存一笔收入。
    await tester.enterText(find.byType(TextField).at(0), '300');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    final saved = await dao.getTransactions();
    expect(saved, hasLength(1));
    final now = DateTime.now();
    expect(saved.single.occurredAt.year, now.year);
    expect(saved.single.occurredAt.month, now.month);
    expect(saved.single.occurredAt.day, now.day);
    // 今天发生的流水：普通 dirty 即可（light 回填覆盖今天）。
    expect(await dao.getSetting('history_sync_dirty'), '1');
    expect(await dao.getSetting('history_full_rebuild'), isNot('1'));

    await db.close();
    await tester.pump();
  });

  testWidgets('流水页点击流水项提供「修改日期」入口', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final accId = await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'));
    final hid = await dao.createHolding(HoldingsCompanion.insert(
      accountId: accId,
      name: '朝朝宝',
      assetType: AssetType.cash.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(83393),
      costPrice: const Value(83393),
      latestPrice: const Value(1),
    ));
    // 一笔发生在 9-21 的卖出（补录场景：真实发生在 9-08）。
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: accId,
      holdingId: Value(hid),
      type: TransactionType.sell.storageName,
      quantity: const Value(99001.95),
      price: const Value(1.0),
      amount: 99001.95,
      currency: const Value('CNY'),
      occurredAt: DateTime(2026, 9, 21, 14, 45),
      costMoved: const Value(true),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: TransactionsPage()),
    ));
    await tester.pumpAndSettle();

    // 点流水项（tile 标题，避开顶部同名筛选 chip）→ 「修改日期」确认对话框。
    await tester.tap(find.descendant(
      of: find.byType(TransactionTile),
      matching: find.text('卖出'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('修改流水日期'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await db.close();
    await tester.pump();
  });
}