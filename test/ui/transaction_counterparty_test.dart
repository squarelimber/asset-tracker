import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/transaction_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

HoldingRow _holding(int id, String name, String type) => HoldingRow(
  id: id,
  accountId: 1,
  name: name,
  assetType: type,
  marketSource: 'manual',
  quantity: 100,
  costPrice: 1,
  costRecorded: true,
  latestPrice: 1,
  currency: 'CNY',
  archived: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  testWidgets('switching from a fund source to sale clears the invalid target', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final target = _holding(1, '目标基金', 'mutual_fund');
    final cash = _holding(2, '现金', 'savings');
    final source = _holding(3, '来源基金', 'mutual_fund');
    await tester.pumpWidget(ProviderScope(
      overrides: [holdingsProvider.overrideWith((ref) => Stream.value([target, cash, source]))],
      child: MaterialApp(home: Scaffold(body: Consumer(
        builder: (context, ref, _) {
          ref.watch(holdingsProvider);
          return TextButton(
            onPressed: () => showHoldingTransactionDialog(context, ref, target),
            child: const Text('打开'),
          );
        },
      ))),
    ));
    await tester.pump();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('来源基金').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('卖出'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final dropdown = tester.widget<DropdownButtonFormField<int>>(
      find.byType(DropdownButtonFormField<int>),
    );
    expect(dropdown.initialValue, isNull);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    expect(find.text('不关联持仓'), findsWidgets);
    await tester.tap(find.textContaining('现金').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不关联持仓').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<DropdownButtonFormField<int>>(
      find.byType(DropdownButtonFormField<int>),
    ).initialValue, isNull);
  });
}
