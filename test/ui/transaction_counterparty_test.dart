import 'dart:async';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/domain/transaction_service.dart';
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

class _PendingService implements TransactionService {
  Completer<TransactionResult> result = Completer<TransactionResult>();
  int calls = 0;

  @override
  Future<TransactionResult> record({
    required int accountId,
    int? holdingId,
    required TransactionType type,
    double? quantity,
    double? price,
    required double amount,
    String currency = 'CNY',
    DateTime? occurredAt,
    int? cashSourceId,
    int? cashTargetId,
    String? note,
  }) {
    calls++;
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'switching from a fund source to sale clears the invalid target',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final target = _holding(1, '目标基金', 'mutual_fund').copyWith(
        quantity: 1900.123449,
        latestPrice: 1.23456,
      );
      final cash = _holding(2, '现金', 'savings');
      final source = _holding(3, '来源基金', 'mutual_fund');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            holdingsProvider.overrideWith(
              (ref) => Stream.value([target, cash, source]),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  ref.watch(holdingsProvider);
                  return TextButton(
                    onPressed: () =>
                        showHoldingTransactionDialog(context, ref, target),
                    child: const Text('打开'),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('来源基金').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('卖出'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部卖出'));
      await tester.pump();
      expect(find.text('1900.123449'), findsOneWidget);
      expect(find.text('1.23456'), findsOneWidget);
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
      expect(
        tester
            .widget<DropdownButtonFormField<int>>(
              find.byType(DropdownButtonFormField<int>),
            )
            .initialValue,
        isNull,
      );
    },
  );

  testWidgets('failed save preserves inputs and blocks repeat submissions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final holding = _holding(1, '现金', 'savings');
    final service = _PendingService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          holdingsProvider.overrideWith((ref) => Stream.value([holding])),
          transactionServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () =>
                    showHoldingTransactionDialog(context, ref, holding),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '23');
    await tester.enterText(find.byType(TextField).last, '保留备注');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(service.calls, 1);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text('保存中…'), findsOneWidget);
    service.result.complete(TransactionResult.fail('余额不足'));
    await tester.pumpAndSettle();
    expect(find.text('余额不足'), findsOneWidget);
    expect(find.text('23'), findsOneWidget);
    expect(find.text('保留备注'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('account transaction failure preserves input for retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026);
    final holding = _holding(1, '现金', 'savings');
    final account = AccountRow(
      id: 1,
      name: '账户',
      type: 'general',
      currency: 'CNY',
      createdAt: now,
      updatedAt: now,
    );
    final service = _PendingService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          holdingsProvider.overrideWith((ref) => Stream.value([holding])),
          accountsProvider.overrideWith((ref) => Stream.value([account])),
          transactionServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showAccountTransactionDialog(context, ref, 1),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '23');
    await tester.enterText(find.byType(TextField).last, '保留备注');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(service.calls, 1);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    service.result.complete(TransactionResult.fail('记账失败'));
    await tester.pumpAndSettle();
    expect(find.text('记账失败'), findsOneWidget);
    expect(find.text('23'), findsOneWidget);
    expect(find.text('保留备注'), findsOneWidget);
    service.result = Completer<TransactionResult>();
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(service.calls, 2);
    service.result.complete(TransactionResult.fail('请重试'));
    await tester.pumpAndSettle();
    expect(find.text('请重试'), findsOneWidget);
    expect(find.text('23'), findsOneWidget);
    expect(find.text('保留备注'), findsOneWidget);
  });
}
