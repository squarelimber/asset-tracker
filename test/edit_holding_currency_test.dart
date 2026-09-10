import 'package:drift/drift.dart' hide Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/holdings/holding_dialogs.dart';

/// Host widget that opens the edit-holding dialog for a given row, so the
/// save path can be driven end-to-end against an in-memory database.
class _EditHost extends ConsumerWidget {
  const _EditHost(this.holding);

  final HoldingRow holding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => showEditHoldingDialog(context, ref, holding),
          child: const Text('编辑'),
        ),
      ),
    );
  }
}

void main() {
  Future<(AppDatabase, AssetDao, HoldingRow)> seedBankWealth(
    WidgetTester tester, {
    required String marketSource,
    String? symbol,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final accId =
        await dao.createAccount(AccountsCompanion.insert(name: '测试账户', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accId,
      name: '美元理财',
      assetType: 'bank_wealth',
      marketSource: Value(marketSource),
      symbol: symbol == null ? const Value.absent() : Value(symbol),
      quantity: const Value(1000),
      costPrice: const Value(1),
      latestPrice: Value(marketSource == 'forex' ? 7.1 : 1),
      currency: const Value('CNY'),
    ));
    return (db, dao, (await dao.getHoldings()).single);
  }

  Finder currencyField() => find.byWidgetPredicate(
        (w) => w is TextField && (w.controller?.text ?? '') == 'CNY',
      );

  testWidgets('manual bank wealth: changing currency to USD is saved',
      (tester) async {
    final (db, dao, holding) = await seedBankWealth(tester, marketSource: 'manual');

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: _EditHost(holding)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    // A manual (non-forex) bank-wealth holding must keep its currency
    // editable — the old code forced the market source to forex on every
    // edit and silently rewrote the currency back to CNY.
    final field = currencyField();
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).enabled, isTrue);

    await tester.enterText(field, 'USD');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = await dao.getHolding(holding.id);
    expect(saved!.currency, 'USD');
    expect(saved.marketSource, 'manual');

    // Drain the delayed controller dispose + drift stream timers.
    await tester.pump(const Duration(milliseconds: 500));
    await db.close();
    await tester.pump();
  });

  testWidgets('forex-linked bank wealth: currency field is locked to CNY',
      (tester) async {
    final (db, dao, holding) =
        await seedBankWealth(tester, marketSource: 'forex', symbol: 'USD');

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: _EditHost(holding)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    // Rate-linked holdings are valued in CNY by construction: the field is
    // visibly disabled instead of silently reverting on save.
    final field = currencyField();
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).enabled, isFalse);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = await dao.getHolding(holding.id);
    expect(saved!.currency, 'CNY');
    expect(saved.marketSource, 'forex');

    await tester.pump(const Duration(milliseconds: 500));
    await db.close();
    await tester.pump();
  });

  testWidgets('unknown asset type is locked and preserved on save (H9)',
      (tester) async {
    final (db, dao, holding) =
        await seedBankWealth(tester, marketSource: 'manual');
    // Simulate a row synced from a newer app version with a type this
    // build does not know.
    final updated = holding.copyWith(
      assetType: 'brand_new_type',
      symbol: const Value('XYZ'),
    );
    await dao.updateHolding(updated);
    final unknown = (await dao.getHolding(holding.id))!;

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: _EditHost(unknown)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    // The warning is shown and the type dropdown is locked.
    expect(find.textContaining('已锁定类型'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = await dao.getHolding(holding.id);
    // The type string and its symbol survive: no silent fallback-to-cash
    // rewrite (which would propagate to every synced device).
    expect(saved!.assetType, 'brand_new_type');
    expect(saved.symbol, 'XYZ');
    expect(saved.marketSource, 'manual');

    await tester.pump(const Duration(milliseconds: 500));
    await db.close();
    await tester.pump();
  });
}
