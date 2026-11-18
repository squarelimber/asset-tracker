import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/formats.dart';
import '../../../core/nav_history.dart';
import '../../../core/symbols.dart';
import '../../../data/database.dart';
import '../../../services/market/fund_nav_source.dart';
import '../../../services/market/history_source.dart';
import '../../components/terminal_card.dart';
import '../../components/terminal_choice.dart';
import '../../tokens.dart';
import 'holding_dialogs.dart';

final fundNavHistoryProvider = FutureProvider.autoDispose
    .family<DailyPriceHistory, String>((ref, code) {
      final client = http.Client();
      ref.onDispose(client.close);
      final today = DateTime.now();
      return FundNavSource(
        client,
      ).fetch(code, today.subtract(const Duration(days: 366)), today);
    });

enum _Range {
  month('近 1 月', 31),
  quarter('近 3 月', 93),
  year('近 1 年', 366),
  all('全部', null);

  const _Range(this.label, this.days);
  final String label;
  final int? days;
}

class HoldingNavTrend extends ConsumerStatefulWidget {
  const HoldingNavTrend({super.key, required this.holding});

  final HoldingRow holding;

  @override
  ConsumerState<HoldingNavTrend> createState() => _HoldingNavTrendState();
}

class _HoldingNavTrendState extends ConsumerState<HoldingNavTrend> {
  _Range? _selected;

  @override
  Widget build(BuildContext context) {
    final holding = widget.holding;
    final manual = hasManualNav(holding);
    final code = holding.symbol?.trim() ?? '';
    final range = _selected ?? (manual ? _Range.all : _Range.quarter);
    final String source = manual ? '手工记录' : '天天基金';
    final Widget content;
    if (manual) {
      content = _series(decodeNavHistory(holding.manualNavHistory), range);
    } else if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      content = Text('填写 6 位基金代码后可查看历史净值。', style: T.label());
    } else {
      content = ref
          .watch(fundNavHistoryProvider(code))
          .when(
            loading: () => const Padding(
              padding: EdgeInsets.all(T.s3),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => Row(
              children: [
                Expanded(child: Text('净值走势加载失败', style: T.label())),
                TextButton(
                  onPressed: () => ref.invalidate(fundNavHistoryProvider(code)),
                  child: const Text('重试'),
                ),
              ],
            ),
            data: (points) => _series(points, range),
          );
    }
    return TerminalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '单位净值走势',
                  style: T.mono(size: 15, weight: FontWeight.w600),
                ),
              ),
              if (manual)
                TextButton.icon(
                  onPressed: () =>
                      showRecordBankNavDialog(context, ref, holding),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('补录净值'),
                ),
            ],
          ),
          Text(source, style: T.label(color: T.text3)),
          const SizedBox(height: T.s2),
          Wrap(
            spacing: T.s1,
            children: [
              for (final option in _Range.values)
                if (manual || option != _Range.all)
                  TerminalChoice(
                    label: option.label,
                    selected: option == range,
                    onPressed: () => setState(() => _selected = option),
                  ),
            ],
          ),
          const SizedBox(height: T.s2),
          content,
        ],
      ),
    );
  }

  Widget _series(DailyPriceHistory values, _Range range) {
    if (values.isEmpty) {
      return Text(
        hasManualNav(widget.holding) ? '暂无净值记录，可补录产品公布的历史净值。' : '暂无公开单位净值。',
        style: T.label(),
      );
    }
    final dates = values.keys.toList()..sort();
    DateTime date(String key) => DateTime.parse('${key}T00:00:00Z');
    final floor = range.days == null
        ? dates.first
        : todayKey(date(dates.last).subtract(Duration(days: range.days!)));
    final visible = dates.where((day) => day.compareTo(floor) >= 0).toList();
    final first = date(visible.first);
    final spots = [
      for (final key in visible)
        FlSpot(date(key).difference(first).inDays.toDouble(), values[key]!),
    ];
    final prices = spots.map((spot) => spot.y);
    final low = prices.reduce(math.min);
    final high = prices.reduce(math.max);
    final padding = high == low
        ? math.max(high * .002, .00001)
        : (high - low) * .12;
    String number(double value) => Formats.plainNum(value, decimals: 6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${visible.last}  ${number(spots.last.y)}',
          style: T.mono(size: 13, weight: FontWeight.w600),
        ),
        const SizedBox(height: T.s2),
        if (spots.length == 1)
          Text('该区间有 1 条净值记录，积累两条后可查看走势。', style: T.label())
        else ...[
          SizedBox(
            height: 170,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: spots.last.x,
                minY: low - padding,
                maxY: high + padding,
                borderData: FlBorderData(show: false),
                gridData: const FlGridData(drawVerticalLine: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  bottomTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 52,
                      interval: (high - low + padding * 2) / 3,
                      getTitlesWidget: (value, _) =>
                          Text(number(value), style: T.label(size: 10)),
                    ),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    color: T.accent,
                    barWidth: 2,
                    dotData: FlDotData(show: hasManualNav(widget.holding)),
                  ),
                ],
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (touched) => [
                      for (final spot in touched)
                        LineTooltipItem(
                          '${visible[spot.spotIndex]}\n${number(spot.y)}',
                          const TextStyle(color: Colors.white, fontSize: 11),
                        ),
                    ],
                  ),
                ),
              ),
              duration: Duration.zero,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 52, top: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(visible.first, style: T.label()),
                Text(visible.last, style: T.label()),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
