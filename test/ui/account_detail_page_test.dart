import 'dart:async';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/accounts/account_detail_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('账户详情切换持仓与流水，显示对方并隐藏金额', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 1, 1);
    final account = AccountRow(
      id: 1,
      name: '一个很长的证券账户名称',
      type: 'general',
      currency: 'CNY',
      createdAt: now,
      updatedAt: now,
    );
    final other = AccountRow(
      id: 2,
      name: '另一个账户',
      type: 'general',
      currency: 'CNY',
      createdAt: now,
      updatedAt: now,
    );
    HoldingRow holding(int id, int accountId, String name) => HoldingRow(
      costRecorded: false,
      id: id,
      accountId: accountId,
      name: name,
      assetType: 'savings',
      marketSource: 'manual',
      quantity: 123456789123,
      costPrice: 0,
      latestPrice: 1,
      currency: 'CNY',
      archived: false,
      createdAt: now,
      updatedAt: now,
    );
    final ownCash = holding(1, 1, '非常长的现金持仓名称用于测试显示');
    final otherCash = holding(2, 2, '对方现金');
    final transaction = TransactionRow(
      id: 1,
      accountId: 1,
      cashSourceId: 1,
      cashTargetId: 2,
      type: 'transfer_out',
      amount: 123456789123,
      currency: 'CNY',
      occurredAt: now,
      costMoved: true,
      internalMove: false,
      updatedAt: now,
    );
    final db = AppDatabase(NativeDatabase.memory());
    final allHoldings = StreamController<List<HoldingRow>>.broadcast();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        historySyncProvider.overrideWith((ref) => null),
        accountProvider(1).overrideWith((ref) async => account),
        accountProvider(2).overrideWith((ref) async => other),
        accountsProvider.overrideWith((ref) => Stream.value([account, other])),
        holdingsProvider.overrideWith((ref) => allHoldings.stream),
        holdingsByAccountProvider(
          1,
        ).overrideWith((ref) => Stream.value([ownCash])),
        holdingsByAccountProvider(
          2,
        ).overrideWith((ref) => Stream.value([otherCash])),
        transactionsByAccountProvider(
          1,
        ).overrideWith((ref) => Stream.value([transaction])),
        transactionsByAccountProvider(
          2,
        ).overrideWith((ref) => Stream.value([transaction])),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await allHoldings.close();
      await db.close();
    });
    container.read(hideAmountsProvider.notifier).state = true;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const AccountDetailPage(accountId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(ownCash.name), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('交易流水'));
    await tester.pumpAndSettle();
    expect(find.text('转账'), findsOneWidget);
    expect(find.text('转出'), findsNothing);
    allHoldings.add([ownCash, otherCash]);
    await tester.pumpAndSettle();
    expect(find.textContaining('另一个账户 / 对方现金'), findsOneWidget);
    expect(find.text('****'), findsOneWidget);
    expect(tester.takeException(), isNull);
    container.read(hideAmountsProvider.notifier).state = false;
    await tester.pumpAndSettle();
    expect(find.textContaining('123,456,789,123'), findsOneWidget);
    expect(find.text('转出'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const AccountDetailPage(accountId: 2),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (find.text('转入').evaluate().isEmpty) {
      await tester.tap(find.text('交易流水'));
      await tester.pumpAndSettle();
    }
    expect(find.text('转入'), findsOneWidget);
    expect(find.textContaining('+¥123,456,789,123'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
