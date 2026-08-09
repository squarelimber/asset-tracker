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
import '../../domain/rate_series.dart';
import '../../services/market/history_lookup.dart';
import '../../services/market/history_source.dart';

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
  bool _showBenchmark = false;
  HistoryPriceLookup? _benchmark;
  _TrendView _view = _TrendView.returnRate;

  /// Segmented range presets (all/custom live behind the calendar button).
  static const _rangeOptions = [
    RangeOption.month1,
    RangeOption.month3,
    RangeOption.ytd,
    RangeOption.year1,
    RangeOption.year3,
  ];

  Future<void> _toggleBenchmark(bool on) async {
    setState(() => _showBenchmark = on);
    if (on && _benchmark == null) {
      try {
        final now = DateTime.now();
        final source = SinaKLineSource();
        // 1000 trading days (~4 years) covers most ranges.
        final history = await source.fetch(
          'sh000300',
          now.subtract(const Duration(days: 1500)),
          now,
        );
        if (history.isNotEmpty && mounted) {
          setState(() => _benchmark = HistoryPriceLookup(history));
        } else if (mounted) {
          setState(() => _showBenchmark = false);
        }
      } catch (_) {
        if (mounted) setState(() => _showBenchmark = false);
      }
    }
  }

  Future<void> _showRangeMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('全部'),
              onTap: () => Navigator.pop(context, 'all'),
            ),
            ListTile(
              title: const Text('自定义日期'),
              onTap: () => Navigator.pop(context, 'custom'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'all') {
      setState(() => _range = RangeOption.all);
    } else if (choice == 'custom') {
      await _pickCustomRange();
    }
  }

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
            // Toolbar: title + view toggle + benchmark chip.
            Row(
              children: [
                Expanded(
                  child: Text('资产走势', style: Theme.of(context).textTheme.titleMedium),
                ),
                SegmentedButton<_TrendView>(
                  segments: const [
                    ButtonSegment(value: _TrendView.returnRate, label: Text('收益率')),
                    ButtonSegment(value: _TrendView.netValue, label: Text('净值')),
                  ],
                  selected: {_view},
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onSelectionChanged: (s) =>
                      setState(() => _view = s.first),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('沪深300'),
                  selected: _showBenchmark,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: _toggleBenchmark,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Range presets + all/custom menu.
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<RangeOption>(
                    segments: [
                      for (final opt in _rangeOptions)
                        ButtonSegment(value: opt, label: Text(opt.label)),
                    ],
                    selected: {_range},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onSelectionChanged: (s) => setState(() => _range = s.first),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '全部 / 自定义日期',
                  icon: const Icon(Icons.calendar_month_outlined, size: 20),
                  visualDensity: VisualDensity.compact,
                  onPressed: _showRangeMenu,
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
            if (_range == RangeOption.all)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('全部历史', style: TextStyle(fontSize: 12)),
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
                final isRate = _view == _TrendView.returnRate;
                final rates = const RateSeriesCalculator().ratesOf(list);
                final rateDelta = const RateSeriesCalculator().rangeRatePct(list);
                final rateAnnualized =
                    const RateSeriesCalculator().annualizedFromRange(list);
                final mainValue = isRate
                    ? (rateDelta ?? 0)
                    : (stats?.profit ?? 0);
                final mainPct = isRate
                    ? (rateDelta ?? 0) / 100
                    : (stats?.profitPct ?? 0);
                final color = context.changeColor(mainValue);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (stats != null) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            isRate
                                ? '${mainValue >= 0 ? '+' : ''}${Formats.pct(mainPct)}'
                                : '${mainValue >= 0 ? '+' : ''}${Formats.money(mainValue)}',
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: color,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          if (!isRate) ...[
                            const SizedBox(width: 10),
                            Text(
                              '${stats.profitPct >= 0 ? '+' : ''}${Formats.pct(stats.profitPct)}',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: color,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isRate
                            ? '区间收益 ${stats.profit >= 0 ? '+' : ''}${Formats.money(stats.profit)}'
                                ' · 年化 ${rateAnnualized == null ? '--' : Formats.pct(rateAnnualized)} · ${stats.days} 天'
                            : '区间年化 ${stats.annualized == null ? '--' : Formats.pct(stats.annualized!)}'
                                ' · ${stats.days} 天',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                    ],
                    // Legend above the chart (no overlay).
                    if (_showBenchmark && _benchmark != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _LegendDot(color: AppColors.up, label: '资产'),
                            const SizedBox(width: 14),
                            _LegendDot(
                              color: Theme.of(context).colorScheme.outline,
                              label: '沪深300',
                              dashed: true,
                            ),
                          ],
                        ),
                      ),
                    _TrendChart(
                      list: list,
                      view: _view,
                      rates: rates,
                      benchmark: _showBenchmark ? _benchmark : null,
                      onDayTap: (date) => _showDayDetail(context, date),
                    ),
                    if (isRate)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          '收益率为当前成本口径近似，已剔除转入资金的影响',
                          style: TextStyle(fontSize: 11),
                        ),
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
                  '当日总资产（折算人民币）${Formats.money(d.totalValue)}',
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
  (ref, day) async {
    final rates = await ref.watch(cnyRatesProvider.future);
    return ref.watch(holdingDetailServiceProvider).compute(day, cnyRates: rates);
  },
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
                      : '单价 ${Formats.smartNum(item.price)} · 成本 ${Formats.money(item.costCny)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              Formats.money(item.marketValueCny),
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

enum _TrendView { returnRate, netValue }

class _TrendChart extends StatelessWidget {
  const _TrendChart({
    required this.list,
    required this.view,
    required this.rates,
    this.benchmark,
    this.onDayTap,
  });

  final List<SnapshotRow> list;

  /// Current view mode.
  final _TrendView view;

  /// Daily return rates (%) aligned with [list] (return-rate view).
  final List<double> rates;

  /// CSI300 index history for the benchmark overlay.
  final HistoryPriceLookup? benchmark;

  /// Called with the tapped snapshot date (yyyy-MM-dd).
  final ValueChanged<String>? onDayTap;

  @override
  Widget build(BuildContext context) {
    // Fixed red brand color for a positive, energetic feel; the line does
    // not change with gains/losses (conveyed by the stats figures instead).
    final color = AppColors.up;
    final isRate = view == _TrendView.returnRate;

    final points = <FlSpot>[];
    var minV = double.infinity;
    var maxV = 0.0;
    for (var i = 0; i < list.length; i++) {
      final v = isRate ? rates[i] : list[i].totalValue;
      points.add(FlSpot(i.toDouble(), v));
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final span = maxV - minV;
    final pad = span == 0 ? maxV.abs() * 0.05 : span * 0.12;
    final longRange = list.length > 250;

    // Benchmark: CSI300 normalized return rate (%), same start point as the
    // portfolio return-rate view: (price / base - 1) * 100.
    final benchSpots = <FlSpot>[];
    if (isRate && benchmark != null) {
      var base = 0.0;
      for (var i = 0; i < list.length; i++) {
        final idx = benchmark!.priceOnOrBefore(list[i].date);
        if (idx == null || idx <= 0) continue;
        if (base == 0) base = idx;
        benchSpots.add(FlSpot(i.toDouble(), (idx / base - 1) * 100));
      }
    }

    String valueText(double v) => isRate
        ? '${v >= 0 ? '+' : ''}${Formats.pct(v / 100)}'
        : Formats.amountCompact(v);

    return SizedBox(
      height: 240,
      child: LineChart(
        LineChartData(
          minY: (minV - pad).clamp(double.negativeInfinity, double.infinity),
          maxY: maxV + pad,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: span == 0 ? 1 : span / 4,
            getDrawingHorizontalLine: (v) => FlLine(
              color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.18),
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
                  valueText(v),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
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
                  return Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  );
                },
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => Theme.of(context).colorScheme.surface,
              tooltipBorder: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              tooltipBorderRadius: BorderRadius.circular(8),
              getTooltipItems: (spots) => [
                for (final spot in spots)
                  LineTooltipItem(
                    '${Formats.date(DateTime.parse(list[spot.x.toInt()].date))}\n'
                    '${isRate ? valueText(spot.y) : Formats.money(spot.y)}',
                    TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
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
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    color.withValues(alpha: 0.22),
                    color.withValues(alpha: 0.02),
                  ],
                ),
              ),
            ),
            if (benchSpots.isNotEmpty)
              LineChartBarData(
                spots: benchSpots,
                isCurved: true,
                curveSmoothness: 0.25,
                color: Theme.of(context).colorScheme.outline,
                barWidth: 1.5,
                dashArray: [4, 4],
                dotData: const FlDotData(show: false),
              ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label, this.dashed = false});

  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size(14, 3),
          painter: _LinePainter(color: color, dashed: dashed),
        ),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  const _LinePainter({required this.color, required this.dashed});

  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    if (!dashed) {
      canvas.drawLine(Offset.zero, Offset(size.width, 0), paint);
      return;
    }
    const dash = 4.0;
    const gap = 3.0;
    var x = 0.0;
    while (x < size.width) {
      final end = (x + dash).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, 0), Offset(end, 0), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.dashed != dashed;
}
