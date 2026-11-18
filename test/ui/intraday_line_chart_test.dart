import 'package:asset_tracker/ui/components/intraday_line_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
