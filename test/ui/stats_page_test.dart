import 'dart:async';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/trade_stats.dart';
import 'package:asset_tracker/ui/pages/stats/stats_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const stats = TradeStats(
    boughtTotal: 12345,
    soldTotal: 45678,
    incomeTotal: 0,
    expenseTotal: 0,
    dividendTotal: 0,
    realizedProfit: 0,
    monthlyCashflow: {},
  );

  testWidgets('快照加载错误与交易统计独立显示', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final snapshots = StreamController<List<SnapshotRow>>();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        snapshotsProvider.overrideWith((ref) => snapshots.stream),
        statsProvider.overrideWith((ref) async => stats),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await snapshots.close();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: const StatsPage()),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('暂无收益数据'), findsNothing);
    snapshots.addError(Exception('offline'));
    await tester.pump();
    expect(find.text('收益数据加载失败，请重试'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('现金支付买入'), 200);
    expect(find.text('现金支付买入'), findsOneWidget);
  });

  testWidgets('隐藏金额覆盖收益及交易统计', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        statsProvider.overrideWith((ref) async => stats),
        snapshotsProvider.overrideWith(
          (ref) => Stream.value([
            SnapshotRow(
              date: '2026-10-01',
              currency: 'CNY',
              totalValue: 100,
              totalCost: 100,
              liabilities: 0,
              createdAt: DateTime(2026),
            ),
            SnapshotRow(
              date: '2026-10-02',
              currency: 'CNY',
              totalValue: 200,
              totalCost: 100,
              liabilities: 0,
              createdAt: DateTime(2026),
            ),
          ]),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: const StatsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('¥12,345.00'), findsNothing);
    expect(find.text('¥100.00'), findsNothing);
    expect(find.text('****'), findsWidgets);
    container.read(hideAmountsProvider.notifier).state = false;
    await tester.pump();
    await tester.scrollUntilVisible(find.text('现金支付买入'), 200);
    expect(find.text('¥12,345.00'), findsOneWidget);
  });
}
