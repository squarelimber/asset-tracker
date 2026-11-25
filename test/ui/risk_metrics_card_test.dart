import 'dart:async';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/core/history_sync.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/ui/pages/stats/risk_metrics_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('同步的新快照可覆盖dirty标记，较新的删除仍阻断直到再次重建', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final now = DateTime.now();
    final rebuiltAt = now.subtract(const Duration(minutes: 1));
    final updates = StreamController<List<SnapshotRow>>();
    List<SnapshotRow> snapshots(DateTime createdAt) => [
      for (var i = 0; i < 34; i++)
        SnapshotRow(
          date: todayKey(now.subtract(Duration(days: 35 - i))),
          currency: 'CNY',
          totalValue: (10000 + i * 10 + (i.isEven ? 3 : -3)).toDouble(),
          totalCost: 10000,
          liabilities: 0,
          profitAdjustment: 0,
          holdingValues: encodeHoldingValues([
            DayHoldingValue(
              holdingId: 1,
              name: '基金',
              type: AssetType.etf,
              value: (10000 + i * 10 + (i.isEven ? 3 : -3)).toDouble(),
              cost: 10000,
              liability: false,
            ),
          ]),
          createdAt: createdAt,
        ),
    ];
    await dao.setSetting(historySyncDirtyKey, historyDirtySet);
    await dao.setSetting(historyFullRebuildKey, '1');
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        snapshotsProvider.overrideWith((ref) => updates.stream),
        holdingsProvider.overrideWith(
          (ref) => Stream.value([
            HoldingRow(
              id: 1,
              accountId: 1,
              name: '基金',
              assetType: 'etf',
              marketSource: 'manual',
              quantity: 100,
              costPrice: 100,
              costRecorded: true,
              latestPrice: 103,
              currency: 'CNY',
              archived: false,
              createdAt: now.subtract(const Duration(days: 60)),
              updatedAt: rebuiltAt,
            ),
          ]),
        ),
        transactionsProvider.overrideWith((ref) => Stream.value([])),
        riskFreeRateProvider.overrideWith((ref) => Stream.value(.01)),
        hideAmountsProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await updates.close();
      await db.close();
    });
    updates.add(snapshots(rebuiltAt));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: RiskMetricsCard())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('--'), findsNothing);
    expect(find.textContaining('有效样本 33 天'), findsOneWidget);
    expect(await dao.getSetting(historySyncDirtyKey), historyDirtySet);
    await dao.upsertTombstone('transactions', 'deleted-flow', deletedAt: now);
    await tester.pumpAndSettle();
    expect(find.text('流水已更新，历史快照待重建后计算'), findsOneWidget);
    expect(find.text('--'), findsNWidgets(2));
    updates.add(snapshots(now.add(const Duration(minutes: 1))));
    await tester.pumpAndSettle();
    expect(find.text('--'), findsNothing);
    expect(find.text('流水已更新，历史快照待重建后计算'), findsNothing);
    expect(await dao.getSetting(historySyncDirtyKey), historyDirtySet);
    expect(await dao.getSetting(historyFullRebuildKey), '1');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('历史重建标记阻止使用流水改期前的旧夏普', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final today = DateTime.now();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        snapshotsProvider.overrideWith(
          (ref) => Stream.value([
            for (var i = 0; i < 34; i++)
              SnapshotRow(
                date: todayKey(today.subtract(Duration(days: 35 - i))),
                currency: 'CNY',
                totalValue: (10000 + i * 10 + (i.isEven ? 3 : -3)).toDouble(),
                totalCost: 10000,
                liabilities: 0,
                createdAt: today,
              ),
          ]),
        ),
        transactionsProvider.overrideWith((ref) => Stream.value([])),
        riskFreeRateProvider.overrideWith((ref) => Stream.value(.01)),
        hideAmountsProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: RiskMetricsCard())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('--'), findsNothing);
    await dao.setSetting(historyFullRebuildKey, '1');
    await tester.pumpAndSettle();
    expect(find.text('流水已更新，历史快照待重建后计算'), findsOneWidget);
    expect(find.text('--'), findsNWidgets(2));
    await dao.setSetting(historySyncDirtyKey, historyDirtySet);
    await dao.setSetting(historyFullRebuildKey, '0');
    await tester.pumpAndSettle();
    expect(find.text('--'), findsNWidgets(2));
    await dao.setSetting(historySyncDirtyKey, historyDirtyClear);
    await tester.pumpAndSettle();
    expect(find.text('流水已更新，历史快照待重建后计算'), findsNothing);
    expect(find.text('--'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('风险指标跟随金额遮罩切换', (tester) async {
    final today = DateTime.now();
    final snapshots = [
      for (var i = 0; i < 34; i++)
        SnapshotRow(
          date: todayKey(today.subtract(Duration(days: 35 - i))),
          currency: 'CNY',
          totalValue: (10000 + i * 10 + (i.isEven ? 3 : -3)).toDouble(),
          totalCost: 10000,
          liabilities: 0,
          createdAt: today,
        ),
    ];
    final container = ProviderContainer(
      overrides: [
        snapshotsProvider.overrideWith((ref) => Stream.value(snapshots)),
        transactionsProvider.overrideWith((ref) => Stream.value([])),
        riskFreeRateProvider.overrideWith((ref) => Stream.value(.01)),
        historyDirtyFlagProvider.overrideWith((ref) => Stream.value('0')),
        historyFullRebuildFlagProvider.overrideWith((ref) => Stream.value('0')),
        hideAmountsProvider.overrideWith((ref) => true),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: RiskMetricsCard())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('****'), findsNWidgets(2));
    container.read(hideAmountsProvider.notifier).state = false;
    await tester.pump();
    expect(find.text('****'), findsNothing);
    expect(find.text('--'), findsNothing);
    expect(find.textContaining('有效样本 33 天'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('风险卡数据不足时不伪造数值，利率可验证并保存', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        snapshotsProvider.overrideWith((ref) => Stream.value([])),
        transactionsProvider.overrideWith((ref) => Stream.value([])),
        riskFreeRateProvider.overrideWith((ref) => Stream.value(.01)),
        historyDirtyFlagProvider.overrideWith((ref) => Stream.value('0')),
        historyFullRebuildFlagProvider.overrideWith((ref) => Stream.value('0')),
        hideAmountsProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: RiskMetricsCard())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('估算夏普比率'), findsOneWidget);
    expect(find.text('--'), findsNWidgets(2));
    expect(find.textContaining('有效样本 0 天'), findsOneWidget);
    await tester.tap(find.textContaining('无风险利率'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '101');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入 -5 到 100'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2.5');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(await AssetDao(db).getSetting(riskFreeRateSettingKey), '0.025');
    expect(find.text('设置无风险年利率'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
