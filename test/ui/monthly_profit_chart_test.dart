import 'package:asset_tracker/ui/components/monthly_profit_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('当前月有数据时默认选中当前月', (tester) async {
    final now = DateTime.now();
    final current = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final before = DateTime(now.year, now.month - 1);
    final previous =
        '${before.year}-${before.month.toString().padLeft(2, '0')}';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MonthlyProfitChart(
            months: {previous: 50, current: 100},
            hideAmounts: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('+¥100.00'), findsOneWidget);
  });

  testWidgets('月度图表选择月份并区分零收益与缺少快照', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MonthlyProfitChart(
            months: {'2026-01': 1234.5, '2026-03': 0, '2026-04': -44},
            hideAmounts: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2026年04月'), findsOneWidget);
    expect(find.text('¥-44.00'), findsOneWidget);
    expect(find.text('缺：无快照  ·  0：零收益'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('monthly-profit-month')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026年02月（无记录）').last);
    await tester.pumpAndSettle();
    expect(find.text('无记录'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('monthly-profit-month')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026年03月').last);
    await tester.pumpAndSettle();
    expect(find.text('+¥0.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏金额时遮罩摘要并隐藏纵轴数值和触摸提示', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MonthlyProfitChart(
            months: {'2026-01': 1234.5, '2026-02': -4.5},
            hideAmounts: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('****'), findsOneWidget);
    expect(find.textContaining('1,234.50'), findsNothing);
    final chart = tester.widget<BarChart>(find.byType(BarChart));
    expect(chart.data.titlesData.leftTitles.sideTitles.showTitles, isFalse);
    expect(chart.data.barTouchData.handleBuiltInTouches, isFalse);
  });
}
