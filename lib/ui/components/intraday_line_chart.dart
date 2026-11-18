import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../tokens.dart';

String minuteLabel(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

class IntradayLineChart extends StatelessWidget {
  static const _open = 570;
  static const _afternoonOpen = 780;

  const IntradayLineChart({
    super.key,
    required this.points,
    required this.formatValue,
    this.markers = const [],
    this.lastMinute = 900,
    this.morningEnd = 690,
    this.maxGap = 10,
  });

  final List<({int minute, double value})> points;
  final String Function(double) formatValue;
  final List<({int minute, double value, Color color})> markers;
  final int lastMinute;
  final int morningEnd;
  final int maxGap;

  @override
  Widget build(BuildContext context) {
    bool inSession(int minute) =>
        minute >= _open &&
        minute <= lastMinute &&
        (minute <= morningEnd || minute >= _afternoonOpen);
    // Keep adjacent coordinates at the join so each observation remains
    // individually selectable. Tooltips recover the original wall time.
    final lunchMinutes = _afternoonOpen - morningEnd - 1;
    int toAxis(int minute) =>
        minute >= _afternoonOpen ? minute - lunchMinutes : minute;
    int fromAxis(int slot) => slot > morningEnd ? slot + lunchMinutes : slot;

    final groups = <List<FlSpot>>[];
    for (final p in points) {
      if (!inSession(p.minute)) continue;
      final x = toAxis(p.minute).toDouble();
      if (groups.isEmpty || x - groups.last.last.x > maxGap) {
        groups.add([]);
      }
      groups.last.add(FlSpot(x, p.value));
    }
    if (groups.isEmpty) return const SizedBox.shrink();
    final visibleMarkers = markers.where((m) => inSession(m.minute)).toList();
    final values = [
      for (final group in groups) ...group.map((p) => p.y),
      ...visibleMarkers.map((m) => m.value),
    ];
    final low = values.reduce(math.min);
    final high = values.reduce(math.max);
    final padding = high > low
        ? (high - low) * .1
        : math.max(low.abs() * .01, .01);
    return Column(
      children: [
        SizedBox(
          height: 175,
          child: LineChart(
            LineChartData(
              minX: _open.toDouble(),
              maxX: toAxis(lastMinute).toDouble(),
              minY: low - padding,
              maxY: high + padding,
              gridData: const FlGridData(drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: const FlTitlesData(show: false),
              lineBarsData: [
                for (final group in groups)
                  LineChartBarData(
                    spots: group,
                    color: T.accent,
                    barWidth: 1.8,
                    dotData: FlDotData(show: group.length == 1),
                  ),
                for (final m in visibleMarkers)
                  LineChartBarData(
                    spots: [FlSpot(toAxis(m.minute).toDouble(), m.value)],
                    color: m.color,
                    dotData: FlDotData(
                      getDotPainter: (_, _, _, _) => FlDotCirclePainter(
                        radius: 4,
                        color: m.color,
                        strokeColor: T.surface,
                        strokeWidth: 1,
                      ),
                    ),
                  ),
              ],
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItems: (items) => [
                    for (final p in items)
                      LineTooltipItem(
                        '${minuteLabel(fromAxis(p.x.round()))}  ${formatValue(p.y)}',
                        const TextStyle(color: Colors.white, fontSize: 11),
                      ),
                  ],
                ),
              ),
            ),
            duration: Duration.zero,
          ),
        ),
        SizedBox(
          height: 20,
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (final (x, label) in [
                (_open.toDouble(), minuteLabel(_open)),
                (
                  morningEnd + .5,
                  '${minuteLabel(morningEnd)} / ${minuteLabel(_afternoonOpen)}',
                ),
                (toAxis(lastMinute).toDouble(), minuteLabel(lastMinute)),
              ])
                Align(
                  alignment: Alignment(
                    2 * (x - _open) / (toAxis(lastMinute) - _open) - 1,
                    0,
                  ),
                  child: Text(label, style: T.label()),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
