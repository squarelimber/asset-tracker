import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../data/database.dart';
import '../../../domain/daily_earnings.dart';
import '../../../domain/trade_stats.dart';
import '../../components/app_bar_actions.dart';
import '../../components/error_state.dart';
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
    // Monthly investment profit derived from the daily net-worth snapshots:
    // principal in/out moves the cost basis along with the balance, so these
    // are true gains (cost-basis profit), not cash flows.
    final snapshots = ref.watch(snapshotsProvider).value ?? const [];
    final monthlyProfit = _monthlyProfitOf(snapshots);
    return Scaffold(
      appBar: AppBar(
        title: const Text('统计'),
        actions: const [TerminalAppBarActions()],
      ),
      body: ResponsiveShell(
        child: stats.when(
          data: (s) => RefreshIndicator(
            onRefresh: () async => ref.invalidate(statsProvider),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
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
                    if (monthlyProfit.isNotEmpty) ..._monthTiles(monthlyProfit),
                  ],
                ),
              const SizedBox(height: T.s4),
              const SectionHeader(label: '月度收益'),
              if (monthlyProfit.isEmpty)
                const TerminalCard(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(T.s4),
                      child: Text('暂无收益数据，每日打开 App 自动记录净值'),
                    ),
                  ),
                )
              else
                TerminalCard(
                  child: SizedBox(
                    height: 220,
                    child: _MonthlyBarChart(months: monthlyProfit),
                  ),
                ),
                const SizedBox(height: T.s3),
                Text(
                  '已落袋收益为卖出（卖出价 − 当前成本价）× 数量 的估算；'
                  '买入后成本变动时会略有偏差。',
                  style: T.label(),
                ),
                const SizedBox(height: T.s2),
                Text(
                  '月度收益来自每日净值快照（当日收益 = 当日净增值 − 前日净增值，'
                  '转入转出本金不计入）；盈利月份 = 当月收益为正。',
                  style: T.label(),
                ),
              ],
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(
            message: '统计计算失败，请重试',
            onRetry: () => ref.invalidate(statsProvider),
          ),
        ),
      ),
    );
  }

  /// Best / worst month and the share of profitable months, derived from the
  /// monthly investment profit (a month is profitable when it actually made
  /// money — cash flows have no bearing on profitability).
  List<Widget> _monthTiles(Map<String, double> months) {
    var bestKey = months.keys.first;
    var worstKey = months.keys.first;
    for (final k in months.keys) {
      if (months[k]! > months[bestKey]!) bestKey = k;
      if (months[k]! < months[worstKey]!) worstKey = k;
    }
    final positive = months.values.where((v) => v > 0).length;
    return [
      StatTile(
        label: '最佳月份 $bestKey',
        value: '${months[bestKey]! >= 0 ? '+' : ''}${Formats.amount(months[bestKey]!)}',
        color: T.changeColor(months[bestKey]!),
      ),
      StatTile(
        label: '最差月份 $worstKey',
        value: Formats.amount(months[worstKey]!),
        color: T.changeColor(months[worstKey]!),
      ),
      StatTile(
        label: '盈利月份占比',
        value: '${(positive / months.length * 100).toStringAsFixed(0)}%',
      ),
    ];
  }

  /// 'yyyy-MM' -> sum of that month's daily asset profits, computed from the
  /// daily net-worth snapshots. Principal in/out moves the cost basis along
  /// with the balance, so these are gains (not cash flows).
  Map<String, double> _monthlyProfitOf(List<SnapshotRow> snapshots) {
    final earnings = const DailyEarningsCalculator().compute(snapshots);
    final byMonth = <String, double>{};
    for (final d in earnings) {
      final key = d.date.substring(0, 7);
      byMonth[key] = (byMonth[key] ?? 0) + d.profit;
    }
    return byMonth;
  }
}

/// Dark terminal-style bar chart of monthly values (investment profit).
class _MonthlyBarChart extends StatelessWidget {
  const _MonthlyBarChart({required this.months});

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
