import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/transaction_service.dart';
import 'package:asset_tracker/ui/pages/holdings/holding_dialogs.dart';
import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';

class _PendingCreation implements TransactionService {
  final result = Completer<int>();

  @override
  Future<int> createHolding(HoldingsCompanion draft, {
    int? redemptionSourceId,
    double redemptionAmount = 0,
    double? price,
  }) => result.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('add holding cannot be dismissed while saving', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    await dao.createAccount(AccountsCompanion.insert(name: '测试账户', type: 'general'));
    final service = _PendingCreation();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        transactionServiceProvider.overrideWithValue(service),
        cnyRatesProvider.overrideWith((ref) async => {'CNY': 1.0}),
        holdingsProvider.overrideWith((ref) => Stream.value([])),
      ],
      child: MaterialApp(home: Scaffold(body: Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () => showAddHoldingDialog(context, ref),
          child: const Text('添加持仓'),
        ),
      ))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加持仓'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '测试基金');
    await tester.enterText(find.byType(TextField).at(2), '100');
    await tester.enterText(find.byType(TextField).at(3), '10');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('保存中…'), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '取消')).onPressed, isNull);
    expect(tester.widget<PopScope>(find.byType(PopScope).last).canPop, isFalse);
    service.result.completeError(ArgumentError('测试失败'));
    await tester.pumpAndSettle();
    expect(find.text('保存'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('add holding dialog saves a share-based holding', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    await dao.createAccount(AccountsCompanion.insert(name: '测试账户', type: 'general'));

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: HoldingsPage()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加持仓'));
    await tester.pumpAndSettle();

    // The dialog shows: account dropdown, type dropdown, name, symbol,
    // quantity, cost, latest, currency, purchase date, note.
    final textFields = find.byType(TextField);
    expect(textFields, findsWidgets);

    // Name (first plain TextField after the two dropdowns).
    await tester.enterText(find.byType(TextField).at(0), '测试基金');
    await tester.enterText(find.byType(TextField).at(1), '600519'); // symbol
    await tester.enterText(find.byType(TextField).at(2), '100'); // qty
    await tester.enterText(find.byType(TextField).at(3), '1500'); // cost
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final holdings = await dao.getHoldings();
    expect(holdings, hasLength(1));
    final h = holdings.single;
    expect(h.name, '测试基金');
    expect(h.symbol, 'sh600519'); // auto-prefixed
    expect(h.quantity, 100);
    expect(h.costPrice, closeTo(1500, 1e-9));
    final opening = (await dao.getTransactions()).single;
    expect(opening.holdingId, h.id);
    expect(opening.amount, 150000);

    // Drain the delayed controller dispose + drift stream timers.
    await tester.pump(const Duration(milliseconds: 500));
    await db.close();
    await tester.pump();
  });

  testWidgets('add liability holding uses the balance form', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    await dao.createAccount(AccountsCompanion.insert(name: '测试账户', type: 'general'));

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: HoldingsPage()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加持仓'));
    await tester.pumpAndSettle();

    // Switch the asset type to 负债 (special picker chip next to the
    // category chips).
    await tester.tap(find.widgetWithText(ChoiceChip, '负债'));
    await tester.pumpAndSettle();

    // The balance form shows the liability label, no symbol/cost/price
    // fields (only name, amount, purchase date, note remain).
    expect(find.text('当前欠款金额'), findsOneWidget);
    expect(find.text('行情代码'), findsNothing);
    expect(find.text('成本单价'), findsNothing);

    await tester.enterText(find.byType(TextField).at(0), '信用卡');
    await tester.enterText(find.byType(TextField).at(1), '3200');
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final holdings = await dao.getHoldings();
    expect(holdings, hasLength(1));
    final h = holdings.single;
    expect(h.assetType, 'liability');
    expect(h.quantity, 3200);
    expect(h.latestPrice, 1); // balance-style: amount tracked in quantity
    expect(h.costPrice, 1); // unit price 1 -> cost = balance, no P/L

    await tester.pump(const Duration(milliseconds: 500));
    await db.close();
    await tester.pump();
  });
}
