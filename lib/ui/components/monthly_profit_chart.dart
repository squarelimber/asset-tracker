import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../tokens.dart';

/// Monthly investment profit. Missing months remain gaps in the chart.
class MonthlyProfitChart extends StatefulWidget {
  const MonthlyProfitChart({
    super.key,
    required this.months,
    required this.hideAmounts,
  });

  final Map<String, double> months;
  final bool hideAmounts;

  @override
  State<MonthlyProfitChart> createState() => _MonthlyProfitChartState();
}

class _MonthlyProfitChartState extends State<MonthlyProfitChart> {
  String? _selected;

  @override
  void didUpdateWidget(covariant MonthlyProfitChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected != null && !widget.months.containsKey(_selected)) {
      _selected = null;
    }
  }

  List<String> _recentCalendarMonths() {
    final dates =
        widget.months.keys
            .map((month) => DateTime.tryParse('$month-01'))
            .whereType<DateTime>()
            .toList()
          ..sort();
    if (dates.isEmpty) return const [];
    final last = dates.last;
    final first = dates.first;
    final start = DateTime(last.year, last.month - 11);
    final begin = first.isAfter(start) ? first : start;
    final months = <String>[];
    for (
      var date = begin;
      !date.isAfter(last);
      date = DateTime(date.year, date.month + 1)
    ) {
      months.add('${date.year}-${date.month.toString().padLeft(2, '0')}');
    }
    return months;
  }

  @override
  Widget build(BuildContext context) {
    final keys = _recentCalendarMonths();
    if (keys.isEmpty) return const SizedBox.shrink();
    final now = DateTime.now();
    final current = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final selected = _selected != null && keys.contains(_selected)
        ? _selected!
        : widget.months.containsKey(current) && keys.contains(current)
        ? current
        : keys.last;
    final selectedValue = widget.months[selected];
    final values = keys.map((key) => widget.months[key]).whereType<double>();
    var minimum = values.fold<double>(0, math.min);
    var maximum = values.fold<double>(0, math.max);
    if (minimum == 0 && maximum == 0) maximum = 1;
    final range = maximum - minimum;
    minimum -= range * 0.12;
    maximum += range * 0.12;
    final step = (maximum - minimum) / 4;
    final containsMissing = keys.any((key) => !widget.months.containsKey(key));
    final containsZero = keys.any((key) => widget.months[key] == 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: T.s2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String>(
              key: const ValueKey('monthly-profit-month'),
              value: selected,
              isDense: true,
              underline: const SizedBox.shrink(),
              dropdownColor: T.surface2,
              style: T.label(size: 13, color: T.text1),
              items: [
                for (final key in keys.reversed)
                  DropdownMenuItem(
                    value: key,
                    child: Text(
                      '${key.substring(0, 4)}年${key.substring(5)}月'
                      '${widget.months.containsKey(key) ? '' : '（无记录）'}',
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _selected = value),
            ),
            Text(
              selectedValue == null
                  ? '无记录'
                  : widget.hideAmounts
                  ? '****'
                  : '${selectedValue >= 0 ? '+' : ''}${Formats.money(selectedValue)}',
              key: const ValueKey('monthly-profit-value'),
              style: T.mono(
                size: 16,
                weight: FontWeight.w600,
                color: widget.hideAmounts || selectedValue == null
                    ? T.text1
                    : T.changeColor(selectedValue),
              ),
            ),
          ],
        ),
        const SizedBox(height: T.s3),
        LayoutBuilder(
          builder: (context, constraints) {
            final labelStep = constraints.maxWidth < 480 && keys.length > 7
                ? 2
                : 1;
            return SizedBox(
              height: 210,
              child: BarChart(
                BarChartData(
                  minY: minimum,
                  maxY: maximum,
                  alignment: BarChartAlignment.spaceAround,
                  borderData: FlBorderData(show: false),
                  extraLinesData: ExtraLinesData(
                    horizontalLines: [
                      HorizontalLine(y: 0, color: T.text3, strokeWidth: 1),
                    ],
                  ),
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    horizontalInterval: step,
                    getDrawingHorizontalLine: (_) =>
                        FlLine(color: T.borderSoft, strokeWidth: 1),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: !widget.hideAmounts,
                        reservedSize: 58,
                        interval: step,
                        getTitlesWidget: (value, meta) => SideTitleWidget(
                          meta: meta,
                          space: 4,
                          child: Text(
                            Formats.amountCompact(value),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: T.mono(size: 10, color: T.text3),
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 42,
                        interval: 1,
                        getTitlesWidget: (value, meta) {
                          final index = value.round();
                          if (index < 0 || index >= keys.length) {
                            return const SizedBox.shrink();
                          }
                          final key = keys[index];
                          final marker = !widget.months.containsKey(key)
                              ? '缺'
                              : !widget.hideAmounts && widget.months[key] == 0
                              ? '0'
                              : '';
                          final date = index % labelStep == 0
                              ? '${key.substring(2, 4)}/${key.substring(5)}'
                              : '';
                          if (date.isEmpty && marker.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return SideTitleWidget(
                            meta: meta,
                            space: 5,
                            child: Text(
                              [
                                date,
                                marker,
                              ].where((part) => part.isNotEmpty).join('\n'),
                              textAlign: TextAlign.center,
                              style: T.mono(size: 10, color: T.text3),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barTouchData: BarTouchData(
                    enabled: true,
                    handleBuiltInTouches: false,
                    touchCallback: (event, response) {
                      final spot = response?.spot;
                      if (!event.isInterestedForInteractions || spot == null) {
                        return;
                      }
                      final index = spot.touchedBarGroupIndex;
                      if (index >= 0 &&
                          index < keys.length &&
                          widget.months.containsKey(keys[index])) {
                        setState(() => _selected = keys[index]);
                      }
                    },
                  ),
                  barGroups: [
                    for (var index = 0; index < keys.length; index++)
                      BarChartGroupData(
                        x: index,
                        barRods: [
                          BarChartRodData(
                            toY: widget.months[keys[index]] ?? 0,
                            width: 12,
                            borderRadius: BorderRadius.circular(2),
                            color: widget.months.containsKey(keys[index])
                                ? T.changeColor(widget.months[keys[index]]!)
                                : Colors.transparent,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        if (containsMissing || (!widget.hideAmounts && containsZero))
          Padding(
            padding: const EdgeInsets.only(top: T.s1),
            child: Text(
              [
                if (containsMissing) '缺：无快照',
                if (!widget.hideAmounts && containsZero) '0：零收益',
              ].join('  ·  '),
              style: T.label(),
            ),
          ),
      ],
    );
  }
}
