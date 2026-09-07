import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';

/// Regression: tapping an asset-type slice in the allocation card (e.g.
/// "场外基金") opens the holdings page with the label as search query; the
/// search must match the type label, not just name/symbol.
void main() {
  testWidgets('search by asset-type label matches holdings of that type',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final acc =
        await dao.createAccount(AccountsCompanion.insert(name: '测试账户', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '某混合基金',
      assetType: 'mutual_fund',
      symbol: const Value('005827'),
      quantity: const Value(1000),
      costPrice: const Value(1.0),
      latestPrice: const Value(1.2),
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '贵州茅台',
      assetType: 'stock',
      symbol: const Value('sh600519'),
      quantity: const Value(100),
      costPrice: const Value(1500),
      latestPrice: const Value(1600),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: HoldingsPage(initialQuery: '场外基金')),
    ));
    await tester.pumpAndSettle();

    // The label query sits in the search field...
    final searchField = tester.widget<TextField>(find.byType(TextField));
    expect(searchField.controller?.text, '场外基金');
    // ...and matches the mutual fund via its type label only
    // (name "某混合基金" and symbol "005827" do not contain it).
    expect(find.text('某混合基金'), findsOneWidget);
    expect(find.text('贵州茅台'), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    await db.close();
    await tester.pump();
  });

  testWidgets('name and symbol search still work', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final acc =
        await dao.createAccount(AccountsCompanion.insert(name: '测试账户', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '某混合基金',
      assetType: 'mutual_fund',
      symbol: const Value('005827'),
      quantity: const Value(1000),
      costPrice: const Value(1.0),
      latestPrice: const Value(1.2),
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '贵州茅台',
      assetType: 'stock',
      symbol: const Value('sh600519'),
      quantity: const Value(100),
      costPrice: const Value(1500),
      latestPrice: const Value(1600),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: HoldingsPage(initialQuery: '600519')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('贵州茅台'), findsOneWidget);
    expect(find.text('某混合基金'), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    await db.close();
    await tester.pump();
  });
}
