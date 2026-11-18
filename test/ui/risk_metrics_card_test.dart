import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/ui/pages/stats/risk_metrics_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
