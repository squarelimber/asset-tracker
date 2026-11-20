import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/core/market_session.dart';
import 'package:asset_tracker/domain/earnings_breakdown.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_intraday.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_intraday_card.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_widgets.dart';
import 'package:asset_tracker/ui/components/terminal_choice.dart';
import 'package:asset_tracker/ui/pages/portfolio/day_detail_sheet.dart';
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
    final now = DateTime.utc(2026, 11, 18, 8);
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
        child: MaterialApp(
          home: Scaffold(body: NetWorthChart(clock: () => now)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('所选区间没有净值记录'), findsOneWidget);
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.byType(LineChart), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('全部')).dy,
      lessThan(tester.getTopLeft(find.byType(LineChart)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('trend chart responds to mouse and touch with a single overlay', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.utc(2026, 11, 18, 8);
    final rows = List.generate(
      3,
      (i) => SnapshotRow(
        date: now
            .subtract(Duration(days: 2 - i))
            .toIso8601String()
            .substring(0, 10),
        currency: 'CNY',
        totalValue: 1100 + i * 100,
        totalCost: 1000,
        liabilities: 0,
        createdAt: now,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          snapshotsProvider.overrideWith((ref) => Stream.value(rows)),
          earningsBreakdownProvider.overrideWith(
            (ref, day) async =>
                EarningsBreakdown(date: todayKey(day), rows: const []),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: NetWorthChart(clock: () => now)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final chart = find.byType(LineChart);
    expect(chart, findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('全部')).dy,
      lessThan(tester.getTopLeft(chart).dy),
    );
    expect(
      tester.widget<LineChart>(chart).data.lineTouchData.handleBuiltInTouches,
      isFalse,
    );
    // The Y-axis consumes 48px on desktop, so the middle point is 24px
    // to the right of the widget's geometric center.
    final center = tester.getCenter(chart) + const Offset(24, 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: center);
    await mouse.moveTo(center + const Offset(1, 0));
    await tester.pump();
    dynamic overlay() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
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
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(find.byType(DayDetailSheet), findsNothing);
    await tester.tap(find.text('查看当日明细'));
    await tester.pumpAndSettle();
    expect(find.byType(DayDetailSheet), findsOneWidget);
  });

  testWidgets('live card closes independently of the historical chart range', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 11, 18, 6, 59);
    final session = ValueNotifier(MarketSession.open);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          snapshotsProvider.overrideWith((ref) => Stream.value([])),
          hideAmountsProvider.overrideWith((ref) => false),
          portfolioIntradayProvider.overrideWith(
            (ref, day) => Stream.value([]),
          ),
          portfolioIntradayHistoryProvider.overrideWith(
            (ref, day) async => (
              points: [
                (minute: 570, profit: 15.0),
                (minute: 571, profit: 10.0),
              ],
              covered: 1,
              eligible: 2,
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ValueListenableBuilder(
                  valueListenable: session,
                  builder: (context, value, _) =>
                      PortfolioIntradayCard(day: '2026-11-18', session: value),
                ),
                NetWorthChart(clock: () => now),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('今日盈亏走势'), findsOneWidget);
    expect(find.text('净值趋势'), findsOneWidget);
    expect(find.text('今日'), findsNothing);
    expect(find.textContaining('截至 09:31'), findsOneWidget);
    expect(find.textContaining('1/2'), findsOneWidget);
    bool selected(String label) => tester
        .widget<TerminalChoice>(find.widgetWithText(TerminalChoice, label))
        .selected;
    expect(selected('今年以来'), isTrue);
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();

    session.value = MarketSession.closed;
    await tester.pump();
    expect(find.text('净值趋势'), findsOneWidget);
    expect(find.text('今日盈亏走势'), findsNothing);
    expect(selected('全部'), isTrue);
  });
}
