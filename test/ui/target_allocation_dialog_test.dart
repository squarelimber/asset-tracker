import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/domain/target_allocation.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_widgets.dart';
import 'package:asset_tracker/ui/pages/portfolio/target_allocation_dialog.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('目标配置显示两位小数并保留未修改的原始精度', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final dao = container.read(daoProvider);
    await saveExactTargetAllocation(dao, {AssetCategory.equity: 33.333333333});
    const summary = PortfolioSummary(
      totalAssets: 3,
      totalLiabilities: 0,
      totalCost: 3,
      todayChange: 0,
      todayChangePct: 0,
      breakdown: [],
      categoryBreakdown: [
        CategoryBreakdown(
          category: AssetCategory.equity,
          marketValue: 1,
          cost: 1,
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: TargetAllocationDialog(summary: summary),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('当前 33.33%'), findsOneWidget);
    final equity = find.byKey(const ValueKey('target-equity'));
    expect(tester.widget<TextField>(equity).controller!.text, '33.33');
    final property = find.byKey(const ValueKey('target-property'));
    await tester.ensureVisible(property);
    await tester.enterText(property, '10');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    final stored = parseTargetAllocation(
      await dao.getSetting(targetAllocationKey),
    );
    expect(stored[AssetCategory.equity], 33.333333333);
    expect(stored[AssetCategory.property], 10);
  });

  test(
    'saving targets retains existing precision and rejects invalid totals',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      final dao = container.read(daoProvider);
      await saveExactTargetAllocation(dao, {
        AssetCategory.equity: 33.333333333,
        AssetCategory.cash: 20,
      });
      final stored = parseTargetAllocation(
        await dao.getSetting(targetAllocationKey),
      );
      expect(stored[AssetCategory.equity], 33.333333333);
      await expectLater(
        saveExactTargetAllocation(dao, {
          AssetCategory.equity: 100,
          AssetCategory.cash: 1,
        }),
        throwsArgumentError,
      );
      expect(
        parseTargetAllocation(
          await dao.getSetting(targetAllocationKey),
        )[AssetCategory.equity],
        33.333333333,
      );
    },
  );

  testWidgets(
    'overview edits allocation, validates total, and saves empty categories',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      const summary = PortfolioSummary(
        totalAssets: 100,
        totalLiabilities: 0,
        totalCost: 100,
        todayChange: 0,
        todayChangePct: 0,
        breakdown: [
          TypeBreakdown(type: AssetType.stock, marketValue: 100, cost: 100),
        ],
        categoryBreakdown: [
          CategoryBreakdown(
            category: AssetCategory.equity,
            marketValue: 100,
            cost: 100,
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: AllocationCard(summary: summary)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('调整目标'));
      await tester.pumpAndSettle();
      expect(find.textContaining('默认参考配置'), findsOneWidget);
      expect(find.byKey(const ValueKey('target-property')), findsOneWidget);

      final property = find.byKey(const ValueKey('target-property'));
      await tester.ensureVisible(property);
      await tester.enterText(property, '10');
      await tester.pump();
      expect(find.textContaining('目标总和不能超过 100%'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );

      final equity = find.byKey(const ValueKey('target-equity'));
      await tester.ensureVisible(equity);
      await tester.enterText(equity, '20');
      await tester.pump();
      expect(find.textContaining('剩余可分配 10.00%'), findsOneWidget);
      expect(find.text('修改尚未保存'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      final stored = parseTargetAllocation(
        await container.read(daoProvider).getSetting(targetAllocationKey),
      );
      expect(stored[AssetCategory.equity], 20);
      expect(stored[AssetCategory.property], 10);
      await tester.tap(find.text('调整目标'));
      await tester.pumpAndSettle();
      expect(find.textContaining('默认参考配置'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('target-property')))
            .controller!
            .text,
        '10.00',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
