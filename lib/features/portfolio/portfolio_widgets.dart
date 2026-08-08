import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/formats.dart';
import '../../domain/portfolio_calculator.dart';

/// Asset allocation donut chart with legend.
class AllocationCard extends ConsumerWidget {
  const AllocationCard({super.key, required this.summary});

  final PortfolioSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final breakdown = summary.breakdown.where((b) => b.marketValue > 0).toList();
    if (breakdown.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('暂无资产配置数据'),
        ),
      );
    }
    final total = summary.totalAssets;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('资产配置', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            SizedBox(
              height: 180,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 48,
                  startDegreeOffset: -90,
                  sections: [
                    for (final b in breakdown)
                      PieChartSectionData(
                        value: b.marketValue,
                        title: Formats.pct(b.marketValue / total),
                        titleStyle: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                        radius: 54,
                        color: b.type.color,
                        showTitle: b.marketValue / total >= 0.04,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            for (final b in breakdown)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: b.type.color,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${b.type.label} (${b.marketValue / total * 100 <= 0.05 ? '<0.1' : (b.marketValue / total * 100).toStringAsFixed(1)}%)',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      Formats.amountCompact(b.marketValue),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Net worth line chart from daily snapshots.
class NetWorthChart extends ConsumerWidget {
  const NetWorthChart({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshots = ref.watch(snapshotsProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('净值走势', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            snapshots.when(
              data: (list) {
                if (list.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('暂无净值数据，每日打开 App 自动记录')),
                  );
                }
                final points = <FlSpot>[];
                var minV = double.infinity;
                var maxV = 0.0;
                for (var i = 0; i < list.length; i++) {
                  final v = list[i].totalValue;
                  points.add(FlSpot(i.toDouble(), v));
                  if (v < minV) minV = v;
                  if (v > maxV) maxV = v;
                }
                final span = maxV - minV;
                final pad = span == 0 ? maxV * 0.05 : span * 0.1;

                return SizedBox(
                  height: 220,
                  child: LineChart(
                    LineChartData(
                      minY: (minV - pad).clamp(0, double.infinity),
                      maxY: maxV + pad,
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: span == 0 ? 1 : span / 4,
                        getDrawingHorizontalLine: (v) => FlLine(
                          color: Theme.of(context)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.3),
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 56,
                            getTitlesWidget: (v, meta) => Text(
                              Formats.amountCompact(v),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: (list.length / 4).ceilToDouble(),
                            reservedSize: 28,
                            getTitlesWidget: (v, meta) {
                              final i = v.toInt();
                              if (i < 0 || i >= list.length) {
                                return const SizedBox.shrink();
                              }
                              final d = DateTime.tryParse(list[i].date);
                              return Text(
                                d == null ? '' : '${d.month}-${d.day}',
                                style: Theme.of(context).textTheme.bodySmall,
                              );
                            },
                          ),
                        ),
                        topTitles:
                            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles:
                            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: points,
                          isCurved: true,
                          curveSmoothness: 0.25,
                          color: AppColors.primary,
                          barWidth: 2,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: AppColors.primary.withValues(alpha: 0.08),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
              loading: () => const SizedBox(
                height: 220,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('加载失败: $e'),
            ),
          ],
        ),
      ),
    );
  }
}
