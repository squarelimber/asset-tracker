import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/transaction_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('账户流水仅从当前账户选择来源，转账目标需要明确选择', (tester) async {
    final now = DateTime(2026, 1, 1);
    AccountRow account(int id, String name) => AccountRow(
      id: id,
      name: name,
      type: 'general',
      currency: 'CNY',
      createdAt: now,
      updatedAt: now,
    );
    HoldingRow cash(int id, int accountId) => HoldingRow(
      id: id,
      accountId: accountId,
      name: '现金',
      assetType: 'savings',
      marketSource: 'manual',
      quantity: 100,
      costPrice: 100,
      latestPrice: 1,
      currency: 'CNY',
      archived: false,
      costRecorded: true,
      createdAt: now,
      updatedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith(
            (ref) => Stream.value([account(1, '甲账户'), account(2, '乙账户')]),
          ),
          holdingsProvider.overrideWith(
            (ref) => Stream.value([cash(1, 1), cash(2, 2)]),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showAccountTransactionDialog(context, ref, 2),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final source = tester.widget<MoneyDropdown>(
      find.byType(MoneyDropdown).first,
    );
    final target = tester.widget<MoneyDropdown>(
      find.byType(MoneyDropdown).last,
    );
    expect(source.value.value, 2);
    expect(source.holdings.map((h) => h.id), [2]);
    expect(target.value.value, isNull);
    expect(target.holdings.map((h) => h.id), [1, 2]);
    expect(target.accountNames, {1: '甲账户', 2: '乙账户'});

    await tester.tap(find.text('收入'));
    await tester.pumpAndSettle();
    final income = tester.widget<MoneyDropdown>(find.byType(MoneyDropdown));
    expect(income.value.value, 2);
    expect(income.holdings.map((h) => h.id), [2]);
  });
}
