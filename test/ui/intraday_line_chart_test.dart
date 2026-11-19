import 'package:asset_tracker/ui/components/intraday_line_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('uses the same grid style at zero on a phone', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IntradayLineChart(
            points: const [
              (minute: 570, value: -300),
              (minute: 575, value: 600),
            ],
            formatValue: (value) => '¥${value.toStringAsFixed(2)}',
            formatAxisValue: (value) =>
                '${value < 0 ? '-' : ''}¥${value.abs().round()}',
            gridAtBounds: true,
            height: 150,
          ),
        ),
      ),
    );
    final chart = tester.widget<LineChart>(find.byType(LineChart)).data;
    expect(chart.titlesData.leftTitles.sideTitles.showTitles, isTrue);
    final lines = chart.extraLinesData.horizontalLines;
    expect(lines.map((line) => line.y), containsAll([chart.minY, 0, chart.maxY]));
    final zero = lines.singleWhere((line) => line.y == 0);
    for (final line in lines) {
      expect(line.color, zero.color);
      expect(line.strokeWidth, zero.strokeWidth);
      expect(line.dashArray, [4, 4]);
    }
    expect(find.text('-¥500'), findsOneWidget);
    expect(find.text('¥0'), findsOneWidget);
    expect(find.text('¥500'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('09:30')).dx,
      greaterThan(tester.getTopLeft(find.byType(LineChart)).dx),
    );
    expect(tester.takeException(), isNull);
  });

  for (final (morningEnd, close) in [(690, 900), (720, 960)]) {
    testWidgets('compresses the lunch break after $morningEnd', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IntradayLineChart(
              morningEnd: morningEnd,
              lastMinute: close,
              points: [
                (minute: morningEnd, value: 1),
                (minute: 750, value: 50),
                (minute: 780, value: 2),
                (minute: 800, value: 3),
              ],
              markers: const [(minute: 780, value: 2, color: Colors.green)],
              formatValue: (value) => value.toStringAsFixed(1),
            ),
          ),
        ),
      );
      final chart = tester.widget<LineChart>(find.byType(LineChart)).data;
      final bars = chart.lineBarsData;
      final join = morningEnd.toDouble();
      expect(bars[0].spots, [FlSpot(join, 1), FlSpot(join + 1, 2)]);
      expect(bars[1].spots, [FlSpot(join + 21, 3)]);
      expect(bars[2].spots.single.x, join + 1);
      expect(find.text('${minuteLabel(morningEnd)} / 13:00'), findsOneWidget);
      final tooltip = chart.lineTouchData.touchTooltipData.getTooltipItems([
        LineBarSpot(bars[0], 0, bars[0].spots.first),
        LineBarSpot(bars[0], 0, bars[0].spots.last),
      ]);
      expect(tooltip.map((item) => item?.text), [
        '${minuteLabel(morningEnd)}  1.0',
        '13:00  2.0',
      ]);
    });
  }
}
