import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';

void main() {
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

    // Switch the asset type to 负债 (last item in the dropdown).
    await tester.tap(find.byType(DropdownButtonFormField<AssetType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('负债').last);
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
