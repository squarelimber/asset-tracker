import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../domain/trade_stats.dart';
import '../../components/app_bar_actions.dart';
import '../../components/kpi_grid.dart';
import '../../components/section_header.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

final statsProvider = FutureProvider<TradeStats>((ref) async {
  final txns = await ref.watch(transactionsProvider.future);
  final holdings = await ref.watch(holdingsProvider.future);
  final rates = await ref.watch(cnyRatesProvider.future);
  return const TradeStatsCalculator().compute(txns, holdings, cnyRates: rates);
});

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('统计'),
        actions: const [TerminalAppBarActions()],
      ),
      body: ResponsiveShell(
        child: stats.when(
          data: (s) => ListView(
            children: [
              KpiGrid(
                tiles: [
                  StatTile(
                    label: '净现金流',
                    value:
                        '${s.cashflow >= 0 ? '+' : ''}${Formats.amount(s.cashflow)}',
                    color: T.changeColor(s.cashflow),
                  ),
                  StatTile(
                    label: '已落袋收益',
                    value: '${s.realizedProfit >= 0 ? '+' : ''}${Formats.amount(s.realizedProfit)}',
                    color: T.changeColor(s.realizedProfit),
                  ),
                  StatTile(label: '累计分红', value: Formats.amount(s.dividendTotal)),
                  StatTile(label: '累计买入', value: Formats.amount(s.boughtTotal)),
                  StatTile(label: '累计卖出', value: Formats.amount(s.soldTotal)),
                  StatTile(label: '累计收入', value: Formats.amount(s.incomeTotal)),
                  StatTile(label: '累计支出', value: Formats.amount(s.expenseTotal)),
                ],
              ),
              const SizedBox(height: T.s4),
              const SectionHeader(label: '月度现金流'),
              if (s.monthlyCashflow.isEmpty)
                const TerminalCard(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(T.s4),
                      child: Text('暂无流水数据，先记一笔交易吧'),
                    ),
                  ),
                )
              else
                TerminalCard(
                  child: SizedBox(
                    height: 220,
                    child: _CashflowChart(months: s.monthlyCashflow),
                  ),
                ),
              const SizedBox(height: T.s3),
              Text(
                '已落袋收益为卖出（卖出价 − 当前成本价）× 数量 的估算；'
                '买入后成本变动时会略有偏差。',
                style: T.label(),
              ),
            ],
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载失败: $e')),
        ),
      ),
    );
  }
}

/// Dark terminal-style bar chart of monthly net cash flow.
class _CashflowChart extends StatelessWidget {
  const _CashflowChart({required this.months});

  final Map<String, double> months;

  @override
  Widget build(BuildContext context) {
    final keys = months.keys.toList()..sort();
    final values = [for (final k in keys) months[k]!];
    final n = keys.length;
    var lo = values.fold(0.0, (m, v) => v < m ? v : m);
    var hi = values.fold(0.0, (m, v) => v > m ? v : m);
    if (hi <= lo) hi = lo + 1;
    final pad = (hi - lo) * 0.15;
    lo -= pad;
    hi += pad;
    return BarChart(
      BarChartData(
        minY: lo,
        maxY: hi,
        gridData: FlGridData(
          drawHorizontalLine: true,
          getDrawingHorizontalLine: (y) => FlLine(
            color: T.borderSoft,
            strokeWidth: 1,
            dashArray: const [4, 4],
          ),
          drawVerticalLine: false,
        ),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => T.surface2,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final v = values[groupIndex];
              return BarTooltipItem(
                '${keys[groupIndex]}  ${v >= 0 ? '+' : ''}${Formats.amount(v)}',
                T.mono(size: 12, color: T.text1),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1 / n,
              minIncluded: false,
              maxIncluded: true,
              getTitlesWidget: (value, meta) {
                final i = (value * n).round() - 1;
                if (i < 0 || i >= n) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    keys[i].substring(5),
                    style: T.mono(size: 10, color: T.text3),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < n; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: values[i],
                  width: 14,
                  borderRadius: BorderRadius.circular(3),
                  color: T.changeColor(values[i]),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
