import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../data/database.dart';
import '../../domain/holding_details.dart';
import '../../domain/portfolio_calculator.dart';
import '../../domain/range_stats.dart';

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

/// Alipay-style net worth trend: range selector + range stats + touch chart.
class NetWorthChart extends ConsumerStatefulWidget {
  const NetWorthChart({super.key});

  @override
  ConsumerState<NetWorthChart> createState() => _NetWorthChartState();
}

class _NetWorthChartState extends ConsumerState<NetWorthChart> {
  RangeOption _range = RangeOption.year1;
  DateTime? _customFrom;
  DateTime? _customTo;

  static const _options = [
    RangeOption.month1,
    RangeOption.month3,
    RangeOption.ytd,
    RangeOption.year1,
    RangeOption.year3,
    RangeOption.all,
    RangeOption.custom,
  ];

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final from = await showDatePicker(
      context: context,
      initialDate: _customFrom ?? now.subtract(const Duration(days: 90)),
      firstDate: DateTime(2000),
      lastDate: now,
      helpText: '选择起始日期',
    );
    if (from == null || !mounted) return;
    final to = await showDatePicker(
      context: context,
      initialDate: _customTo ?? now,
      firstDate: from,
      lastDate: now,
      helpText: '选择结束日期',
    );
    if (to == null) return;
    setState(() {
      _customFrom = from;
      _customTo = to;
      _range = RangeOption.custom;
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshots = ref.watch(snapshotsProvider);
    return Card(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('资产走势', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final opt in _options)
                  ChoiceChip(
                    label: Text(opt.label),
                    selected: _range == opt,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) {
                      if (opt == RangeOption.custom) {
                        _pickCustomRange();
                      } else {
                        setState(() => _range = opt);
                      }
                    },
                  ),
              ],
            ),
            if (_range == RangeOption.custom && _customFrom != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${Formats.date(_customFrom!)} ~ ${Formats.date(_customTo ?? DateTime.now())}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            snapshots.when(
              data: (all) {
                final now = DateTime.now();
                final startDate = _range == RangeOption.custom
                    ? _customFrom
                    : _range.startDate(now);
                final endDate = _range == RangeOption.custom
                    ? _customTo
                    : (_range == RangeOption.all ? null : now);
                final list = const RangeStatsCalculator().filter(
                  all,
                  from: startDate == null ? null : Formats.date(startDate),
                  to: endDate == null ? null : Formats.date(endDate),
                );
                if (list.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('暂无净值数据，每日打开 App 自动记录')),
                  );
                }
                final stats = const RangeStatsCalculator().compute(list);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (stats != null) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '${stats.profit >= 0 ? '+' : ''}${Formats.money(stats.profit)}',
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: context.changeColor(stats.profit),
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '${stats.profitPct >= 0 ? '+' : ''}${Formats.pct(stats.profitPct)}',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: context.changeColor(stats.profit),
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '区间年化 ${stats.annualized == null ? '--' : Formats.pct(stats.annualized!)}'
                        ' · ${stats.days} 天',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                    ],
                    _TrendChart(
                      list: list,
                      onDayTap: (date) => _showDayDetail(context, date),
                    ),
                  ],
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

  /// Bottom sheet with the per-holding breakdown of the tapped day.
  Future<void> _showDayDetail(BuildContext context, String date) async {
    final day = DateTime.tryParse(date);
    if (day == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _DayDetailSheet(date: day),
    );
  }
}

class _DayDetailSheet extends ConsumerWidget {
  const _DayDetailSheet({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(_dayDetailProvider(date));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: detail.when(
          data: (d) {
            if (d == null) {
              return const SizedBox(height: 120, child: Center(child: Text('无数据')));
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${Formats.date(date)} 持仓明细',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '当日总资产 ${Formats.money(d.totalValue)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final item in d.items)
                        _DetailRow(item: item),
                      const Divider(height: 16),
                      Text(
                        '点击走势图任意日期可查看当天明细',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
          loading: () => const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => SizedBox(
            height: 120,
            child: Center(child: Text('加载失败: $e')),
          ),
        ),
      ),
    );
  }
}

final _dayDetailProvider = FutureProvider.autoDispose.family<DayDetail?, DateTime>(
  (ref, day) => ref.watch(holdingDetailServiceProvider).compute(day),
);class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.item});

  final HoldingDayDetail item;

  @override
  Widget build(BuildContext context) {
    final type = AssetType.fromStorage(item.holding.assetType);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(type.icon, size: 18, color: type.color),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.holding.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Text(
                  type == AssetType.liability
                      ? '负债'
                      : '单价 ${Formats.smartNum(item.price)} · 成本 ${Formats.money(item.cost, item.holding.currency)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              Formats.money(item.marketValue, item.holding.currency),
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${(item.ratio * 100).toStringAsFixed(1)}%',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.list, this.onDayTap});

  final List<SnapshotRow> list;

  /// Called with the tapped snapshot date (yyyy-MM-dd).
  final ValueChanged<String>? onDayTap;

  @override
  Widget build(BuildContext context) {
    // Fixed red brand color for a positive, energetic feel; the line does
    // not change with gains/losses (conveyed by the stats figures instead).
    final color = AppColors.up;
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
    final longRange = list.length > 250;

    return SizedBox(
      height: 240,
      child: LineChart(
        LineChartData(
          minY: (minV - pad).clamp(0, double.infinity),
          maxY: maxV + pad,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: span == 0 ? 1 : span / 4,
            getDrawingHorizontalLine: (v) => FlLine(
              color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
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
                  if (i < 0 || i >= list.length) return const SizedBox.shrink();
                  final d = DateTime.tryParse(list[i].date);
                  if (d == null) return const SizedBox.shrink();
                  final label = longRange ? '${d.year % 100}-${d.month}' : '${d.month}-${d.day}';
                  return Text(label, style: Theme.of(context).textTheme.bodySmall);
                },
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => [
                for (final spot in spots)
                  LineTooltipItem(
                    '${Formats.date(DateTime.parse(list[spot.x.toInt()].date))}\n'
                    '${Formats.money(spot.y)}',
                    TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            touchCallback: (event, response) {
              // Single tap on a spot opens the day detail panel.
              if (event is FlTapUpEvent && response != null) {
                final spots = response.lineBarSpots;
                if (spots != null && spots.isNotEmpty) {
                  final idx = spots.first.x.toInt();
                  if (idx >= 0 && idx < list.length) {
                    onDayTap?.call(list[idx].date);
                  }
                }
              }
            },
          ),
          lineBarsData: [
            LineChartBarData(
              spots: points,
              isCurved: true,
              curveSmoothness: 0.25,
              color: color,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    color.withValues(alpha: 0.25),
                    color.withValues(alpha: 0.02),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
