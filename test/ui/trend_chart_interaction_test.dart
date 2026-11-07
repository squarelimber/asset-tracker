import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_widgets.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a range without snapshots can be changed on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final previousYear = DateTime(now.year - 1, 6, 15);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          snapshotsProvider.overrideWith(
            (ref) => Stream.value([
              SnapshotRow(
                date: previousYear.toIso8601String().substring(0, 10),
                currency: 'CNY',
                totalValue: 1100,
                totalCost: 1000,
                liabilities: 0,
                createdAt: previousYear,
              ),
            ]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: NetWorthChart())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('所选区间没有净值记录'), findsOneWidget);
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.byType(LineChart), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('trend chart responds to mouse and touch with a single overlay', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final rows = List.generate(3, (i) => SnapshotRow(
      date: now.subtract(Duration(days: 2 - i)).toIso8601String().substring(0, 10),
      currency: 'CNY', totalValue: 1100 + i * 100,
      totalCost: 1000, liabilities: 0, createdAt: now,
    ));
    await tester.pumpWidget(ProviderScope(
      overrides: [snapshotsProvider.overrideWith((ref) => Stream.value(rows))],
      child: const MaterialApp(home: Scaffold(body: NetWorthChart())),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final chart = find.byType(LineChart);
    expect(chart, findsOneWidget);
    expect(tester.widget<LineChart>(chart).data.lineTouchData.handleBuiltInTouches, isFalse);
    // The Y-axis consumes 48px on desktop, so the middle point is 24px
    // to the right of the widget's geometric center.
    final center = tester.getCenter(chart) + const Offset(24, 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: center);
    await mouse.moveTo(center + const Offset(1, 0));
    await tester.pump();
    dynamic overlay() => tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .firstWhere((p) => p.runtimeType.toString() == '_TrendOverlayPainter');
    expect(overlay().hoverIndex, isNotNull);
    await mouse.removePointer();
    await tester.pump();
    expect(overlay().hoverIndex, isNull);
    final touch = await tester.startGesture(center);
    await touch.moveBy(const Offset(1, 0));
    await tester.pump();
    expect(overlay().hoverIndex, isNotNull);
    expect(tester.takeException(), isNull);
    await touch.cancel();
    await tester.pump();
    expect(overlay().hoverIndex, isNull);
  });
}
