import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../domain/nice_ticks.dart';
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
    this.formatAxisValue = Formats.num,
    this.markers = const [],
    this.lastMinute = 900,
    this.morningEnd = 690,
    this.maxGap = 10,
    this.color = T.accent,
    this.height = 175,
    this.showZeroLine = false,
  });

  final List<({int minute, double value})> points;
  final String Function(double) formatValue;
  final String Function(double) formatAxisValue;
  final List<({int minute, double value, Color color})> markers;
  final int lastMinute;
  final int morningEnd;
  final int maxGap;
  final Color color;
  final double height;
  final bool showZeroLine;

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
      if (!inSession(p.minute) || !p.value.isFinite) continue;
      final x = toAxis(p.minute).toDouble();
      if (groups.isEmpty || x - groups.last.last.x > maxGap) {
        groups.add([]);
      }
      groups.last.add(FlSpot(x, p.value));
    }
    if (groups.isEmpty) return const SizedBox.shrink();
    final visibleMarkers = markers
        .where((m) => inSession(m.minute) && m.value.isFinite)
        .toList();
    final values = [
      for (final group in groups) ...group.map((p) => p.y),
      ...visibleMarkers.map((m) => m.value),
    ];
    final low = values.reduce(math.min);
    final high = values.reduce(math.max);
    // NiceAxis uses two decimal places for small values. Keep its entire
    // range wide enough for distinct ticks even for a single or flat sample.
    final padding = math.max((high - low) * .10, .02);
    final ticks = NiceAxis.ticks(
      low - padding,
      high + padding,
      targetCount: height <= 175 ? 3 : 4,
    );
    final visibleZero =
        showZeroLine && ticks.ticks.first <= 0 && ticks.ticks.last >= 0;
    final labelStyle = T.mono(size: 10, color: T.text3);
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    var widest = 0.0;
    for (final tick in ticks.ticks) {
      painter.text = TextSpan(text: formatAxisValue(tick), style: labelStyle);
      painter.layout();
      widest = math.max(widest, painter.width);
    }
    painter.dispose();
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = (widest + T.s2)
            .clamp(26.0, math.max(26.0, constraints.maxWidth * .35))
            .toDouble();
        return Column(
          children: [
            SizedBox(
              height: height,
              child: LineChart(
                LineChartData(
                  minX: _open.toDouble(),
                  maxX: toAxis(lastMinute).toDouble(),
                  minY: ticks.ticks.first,
                  maxY: ticks.ticks.last,
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    horizontalInterval: ticks.step,
                    getDrawingHorizontalLine: (_) => const FlLine(
                      color: T.borderSoft,
                      strokeWidth: 1,
                      dashArray: [4, 4],
                    ),
                  ),
                  extraLinesData: ExtraLinesData(
                    horizontalLines: [
                      if (visibleZero)
                        HorizontalLine(y: 0, color: T.text3, strokeWidth: 1),
                    ],
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    bottomTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: ticks.step,
                        reservedSize: gutter,
                        getTitlesWidget: (value, _) => Padding(
                          padding: const EdgeInsets.only(right: T.s1),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                formatAxisValue(value),
                                style: labelStyle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  lineBarsData: [
                    for (final group in groups)
                      LineChartBarData(
                        spots: group,
                        color: color,
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
                            T.mono(size: 11),
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
              child: Padding(
                padding: EdgeInsets.only(left: gutter),
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
                        child: Text(label, style: labelStyle),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
