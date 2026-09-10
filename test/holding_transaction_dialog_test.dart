import 'package:drift/drift.dart' hide Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/transaction_dialogs.dart';

/// Host that resolves the holdings stream, then opens the per-holding
/// transaction dialog — driving the real record() path end to end.
class _TxnHost extends ConsumerWidget {
  const _TxnHost(this.holding);

  final HoldingRow holding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdings = ref.watch(holdingsProvider).value ?? const [];
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('持仓数：${holdings.length}'),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () =>
                  showHoldingTransactionDialog(context, ref, holding),
              child: const Text('记一笔'),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  Future<(AppDatabase, AssetDao, HoldingRow)> seed(
    WidgetTester tester,
    HoldingsCompanion Function(int accountId) entryOf,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final accId =
        await dao.createAccount(AccountsCompanion.insert(name: '测试账户', type: 'general'));
    await dao.createHolding(entryOf(accId));
    return (db, dao, (await dao.getHoldings()).single);
  }

  testWidgets('expense on a cash holding actually debits the balance',
      (tester) async {
    final (db, dao, holding) = await seed(
      tester,
      (accId) => HoldingsCompanion.insert(
        accountId: accId,
        name: '零钱',
        assetType: 'savings',
        marketSource: const Value('manual'),
        quantity: const Value(10000),
        costPrice: const Value(10000),
        latestPrice: const Value(1),
      ),
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: _TxnHost(holding)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('记一笔'));
    await tester.pumpAndSettle();

    // The dialog defaults to 收入; switch to 支出 and save an amount.
    await tester.tap(find.text('支出'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '300');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // Old bug: the dialog passed holding.id as cashSourceId while the
    // service reads cashTargetId for expenses — every save failed with
    // "需要指定现金持仓" and the balance never moved.
    final saved = await dao.getHolding(holding.id);
    expect(saved!.quantity, closeTo(9700, 1e-9));
    expect(saved.costPrice, closeTo(9700, 1e-9));

    await tester.pump(const Duration(milliseconds: 500));
    await db.close();
    await tester.pump();
  });

  testWidgets('bond holding gets buy/sell segments (share-like types)',
      (tester) async {
    final (db, dao, holding) = await seed(
      tester,
      (accId) => HoldingsCompanion.insert(
        accountId: accId,
        name: '国债',
        assetType: 'bond',
        marketSource: const Value('manual'),
        quantity: const Value(100),
        costPrice: const Value(100),
        latestPrice: const Value(100),
      ),
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: _TxnHost(holding)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('记一笔'));
    await tester.pumpAndSettle();

    // Old bug: bond/futures fell into the income/expense branch, whose
    // options all fail at save; buy/sell were unreachable.
    expect(find.text('买入'), findsOneWidget);
    expect(find.text('卖出'), findsOneWidget);
    expect(find.text('收入'), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    await db.close();
    await tester.pump();
  });
}
