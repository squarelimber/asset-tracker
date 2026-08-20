import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../data/database.dart';
import '../../domain/chart_downsample.dart';
import '../../domain/nice_ticks.dart';
import '../../domain/portfolio_calculator.dart';
import '../../domain/range_stats.dart';
import '../../domain/rate_series.dart';
import '../../services/market/history_lookup.dart';
import '../../services/market/history_source.dart';
import '../../services/market/tencent_history_source.dart';
import 'day_detail_sheet.dart';

enum _AllocationView { byType, byRisk }

/// Asset allocation donut with dimension switch (type/risk), interactive
/// center (total or selected slice), tap highlight and ratio-bar legend.
class AllocationCard extends ConsumerStatefulWidget {
  const AllocationCard({super.key, required this.summary});

  final PortfolioSummary summary;

  @override
  ConsumerState<AllocationCard> createState() => _AllocationCardState();
}

class _AllocationCardState extends ConsumerState<AllocationCard> {
  _AllocationView _view = _AllocationView.byType;
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final breakdown = summary.breakdown.where((b) => b.marketValue > 0).toList();
    final riskBreakdown =
        summary.riskBreakdown.where((b) => b.marketValue > 0).toList();
    if (breakdown.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('暂无资产配置数据'),
        ),
      );
    }
    final total = summary.totalAssets;
    final hidden = ref.watch(hideAmountsProvider);
    String amountText(double v) =>
        hidden ? Formats.masked() : Formats.amountCompact(v);

    // Unified entry view: label + color + value + ratio.
    final entries = _view == _AllocationView.byType
        ? [
            for (final b in breakdown)
              (
                label: b.type.label,
                color: b.type.color,
                value: b.marketValue,
                amount: amountText(b.marketValue),
              ),
          ]
        : [
            for (final b in riskBreakdown)
              (
                label: b.risk.label,
                color: b.risk.color,
                value: b.marketValue,
                amount: amountText(b.marketValue),
              ),
          ];

    final selected = _selected != null && _selected! < entries.length
        ? entries[_selected!]
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('资产配置', style: Theme.of(context).textTheme.titleMedium),
                ),
                SegmentedButton<_AllocationView>(
                  segments: const [
                    ButtonSegment(value: _AllocationView.byType, label: Text('类型')),
                    ButtonSegment(value: _AllocationView.byRisk, label: Text('风险')),
                  ],
                  selected: {_view},
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onSelectionChanged: (s) => setState(() {
                    _view = s.first;
                    _selected = null;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 52,
                      startDegreeOffset: -90,
                      sections: [
                        for (var i = 0; i < entries.length; i++)
                          PieChartSectionData(
                            value: entries[i].value,
                            title: entries[i].value / total >= 0.04
                                ? '${(entries[i].value / total * 100).toStringAsFixed(1)}%'
                                : '',
                            titleStyle: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            radius: _selected == i ? 60 : 54,
                            color: _selected == null || _selected == i
                                ? entries[i].color
                                : entries[i].color.withValues(alpha: 0.35),
                            showTitle: entries[i].value / total >= 0.04,
                          ),
                      ],
                    ),
                  ),
                    // Interactive center.
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          selected == null ? '总资产' : selected.label,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          selected == null
                              ? amountText(total)
                              : selected.amount,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                        ),
                        if (selected != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${(selected.value / total * 100).toStringAsFixed(1)}%',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: selected.color,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            for (var i = 0; i < entries.length; i++) ...[
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(
                  () => _selected = _selected == i ? null : i,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: entries[i].color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entries[i].label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ),
                                Text(
                                  '${(entries[i].value / total * 100).toStringAsFixed(1)}%',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context).colorScheme.outline,
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: total == 0 ? 0 : entries[i].value / total,
                                minHeight: 4,
                                backgroundColor:
                                    entries[i].color.withValues(alpha: 0.15),
                                color: entries[i].color,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        entries[i].amount,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
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
  RangeOption _range = RangeOption.ytd;
  DateTime? _customFrom;
  DateTime? _customTo;
  _TrendView _view = _TrendView.returnRate;

  /// Benchmark indexes: symbol, label, line color.
  static const _benchIndexes = [
    (code: 'sh000300', label: '沪深300', color: Color(0xFF64B5F6)),
    (code: 'sh000001', label: '上证指数', color: Color(0xFF81C784)),
    (code: 'sh000016', label: '上证50', color: Color(0xFFBA68C8)),
    (code: 'sz399006', label: '创业板指', color: Color(0xFFFFB74D)),
  ];

  /// Max overlaid index lines: more than this is unreadable on a phone.
  static const _maxBenchmarks = 3;

  Set<String> _benchSelected = {};
  Map<String, HistoryPriceLookup> _benchData = {};

  /// Segmented range presets (all/custom live behind the calendar button).
  static const _rangeOptions = [
    RangeOption.month1,
    RangeOption.month3,
    RangeOption.ytd,
    RangeOption.year1,
    RangeOption.year3,
  ];

  Color _benchColor(String code) =>
      _benchIndexes.firstWhere((b) => b.code == code).color;

  Future<void> _showBenchmarkPanel() async {
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('对比指数（收益率视图下叠加显示）',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                for (final b in _benchIndexes) ...[
                  FilterChip(
                    label: Text(b.label),
                    selected: _benchSelected.contains(b.code),
                    visualDensity: VisualDensity.compact,
                    onSelected: (sel) {
                      if (sel) {
                        if (_benchSelected.length >= _maxBenchmarks) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('最多同时对比 3 个指数')),
                          );
                          return;
                        }
                        setSheetState(() => _benchSelected.add(b.code));
                      } else {
                        setSheetState(() => _benchSelected.remove(b.code));
                      }
                    },
                  ),
                  const SizedBox(height: 6),
                ],
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.pop(context, {..._benchSelected}),
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _benchSelected = result);
    await _loadBenchmarks();
  }

  Future<void> _loadBenchmarks() async {
    final missing = _benchSelected
        .where((code) => !_benchData.containsKey(code))
        .toList();
    if (missing.isEmpty) return;
    final now = DateTime.now();
    // Sina K-lines have no CORS support; the web build uses Tencent's.
    final HistoryDataSource source = kIsWeb
        ? TencentHistorySource()
        : SinaKLineSource();
    final data = <String, HistoryPriceLookup>{};
    for (final code in missing) {
      try {
        final history = await source.fetch(
          code,
          now.subtract(const Duration(days: 1500)),
          now,
        );
        if (history.isNotEmpty) {
          data[code] = HistoryPriceLookup(history);
        }
      } catch (_) {
        // Skip failed index.
      }
    }
    if (mounted && data.isNotEmpty) {
      setState(() => _benchData = {..._benchData, ...data});
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
            // Toolbar: title + view toggle + benchmark chip + calendar.
            // On phones the trailing controls wrap onto a second line so the
            // title never gets squeezed into vertical single-char columns.
            _NetWorthToolbar(
              title: Text('资产走势', style: Theme.of(context).textTheme.titleMedium),
              calendar: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '收益日历',
                    icon: const Icon(Icons.event_note_outlined, size: 22),
                    onPressed: () => context.push('/earnings-calendar'),
                  ),
                  IconButton(
                    tooltip: '产品收益日历',
                    icon: const Icon(Icons.table_chart_outlined, size: 22),
                    onPressed: () => context.push('/product-earnings'),
                  ),
                ],
              ),
              trailing: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
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
                  FilterChip(
                    label: Text(
                      _benchSelected.isEmpty
                          ? '指数对比'
                          : '指数对比(${_benchSelected.length})',
                    ),
                    selected: _benchSelected.isNotEmpty,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => _showBenchmarkPanel(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Range presets + all/custom menu. On phones the presets are
            // content-sized ChoiceChips that wrap instead of a full-width
            // stretched segmented button.
            if (Responsive.isPhone(context))
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final opt in _rangeOptions)
                    ChoiceChip(
                      label: Text(opt.label),
                      selected: _range == opt,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onSelected: (_) => setState(() => _range = opt),
                    ),
                  IconButton(
                    tooltip: '全部 / 自定义日期',
                    icon: const Icon(Icons.calendar_month_outlined, size: 20),
                    visualDensity: VisualDensity.compact,
                    onPressed: _showRangeMenu,
                  ),
                ],
              )
            else
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
                      onSelectionChanged: (s) =>
                          setState(() => _range = s.first),
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
                final hideAmounts = ref.watch(hideAmountsProvider);
                String moneyText(double v) =>
                    hideAmounts ? Formats.masked() : Formats.money(v);
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
                                : '${mainValue >= 0 ? '+' : ''}${moneyText(mainValue)}',
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
                            ? '区间收益 ${stats.profit >= 0 ? '+' : ''}${moneyText(stats.profit)}'
                                ' · 年化 ${rateAnnualized == null ? '--' : Formats.pct(rateAnnualized)} · ${stats.days} 天'
                            : '区间年化 ${stats.annualized == null ? '--' : Formats.pct(stats.annualized!)}'
                                ' · ${stats.days} 天',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                    ],
                    // Legend above the chart (no overlay).
                    if (_benchSelected.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 14,
                          runSpacing: 4,
                          children: [
                            _LegendDot(color: AppColors.up, label: '资产'),
                            for (final code in _benchSelected)
                              if (_benchData.containsKey(code))
                                _LegendDot(
                                  color: _benchColor(code),
                                  label: _benchIndexes
                                      .firstWhere((b) => b.code == code)
                                      .label,
                                ),
                          ],
                        ),
                      ),
                    _TrendChart(
                      list: list,
                      view: _view,
                      rates: rates,
                      hideAmounts: hideAmounts,
                      benchmarks: {
                        for (final code in _benchSelected)
                          if (_benchData.containsKey(code))
                            code: _BenchSeries(
                              name: _benchIndexes
                                  .firstWhere((b) => b.code == code)
                                  .label,
                              color: _benchColor(code),
                              lookup: _benchData[code]!,
                            ),
                      },
                      onDayTap: (date) => _showDayDetail(context, date),
                    ),
                    if (isRate)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          '收益率自区间首日归零，与指数同起点对比；已剔除转入资金影响（成本口径近似）',
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
      builder: (context) => DayDetailSheet(date: day),
    );
  }
}

enum _TrendView { returnRate, netValue }

/// Toolbar for the net worth chart. On phones the title keeps its own line
/// so narrow screens never squeeze it into vertical single-char columns;
/// desktop retains the classic single-row layout.
class _NetWorthToolbar extends StatelessWidget {
  const _NetWorthToolbar({
    required this.title,
    required this.calendar,
    required this.trailing,
  });

  final Widget title;
  final Widget calendar;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    if (Responsive.isPhone(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: title),
              calendar,
            ],
          ),
          const SizedBox(height: 4),
          trailing,
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: title),
        calendar,
        const SizedBox(width: 8),
        trailing,
      ],
    );
  }
}

/// One benchmark index overlay series.
class _BenchSeries {
  const _BenchSeries({required this.name, required this.color, required this.lookup});

  final String name;
  final Color color;
  final HistoryPriceLookup lookup;
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({
    required this.list,
    required this.view,
    required this.rates,
    required this.hideAmounts,
    this.benchmarks = const {},
    this.onDayTap,
  });

  final List<SnapshotRow> list;

  /// Current view mode.
  final _TrendView view;

  /// Daily return rates (%) aligned with [list] (return-rate view).
  final List<double> rates;

  /// Privacy toggle: masks monetary labels and tooltips.
  final bool hideAmounts;

  /// Selected benchmark indexes (code -> series).
  final Map<String, _BenchSeries> benchmarks;

  /// Called with the tapped snapshot date (yyyy-MM-dd).
  final ValueChanged<String>? onDayTap;

  /// Point count beyond which the series is downsampled for phone screens.
  static const _denseThreshold = 240;

  @override
  Widget build(BuildContext context) {
    // Fixed red brand color for a positive, energetic feel; the line does
    // not change with gains/losses (conveyed by the stats figures instead).
    final color = AppColors.up;
    final isRate = view == _TrendView.returnRate;
    // Normalize the asset series to start at 0% at the range start, so it
    // shares the same baseline as the normalized index benchmarks: both
    // series compare the return over the selected range.
    final rateBase = isRate && rates.isNotEmpty ? rates.first : 0.0;

    final rawPoints = <FlSpot>[];
    for (var i = 0; i < list.length; i++) {
      final v = isRate ? rates[i] - rateBase : list[i].totalValue;
      rawPoints.add(FlSpot(i.toDouble(), v));
    }
    // Benchmarks: normalized return rates (%), same start point as the
    // portfolio return-rate view: (price / base - 1) * 100.
    final benchRaw = <_BenchSeries, List<FlSpot>>{};
    if (isRate) {
      for (final entry in benchmarks.entries) {
        final series = entry.value;
        final spots = <FlSpot>[];
        var base = 0.0;
        for (var i = 0; i < list.length; i++) {
          final idx = series.lookup.priceOnOrBefore(list[i].date);
          if (idx == null || idx <= 0) continue;
          if (base == 0) base = idx;
          spots.add(FlSpot(i.toDouble(), (idx / base - 1) * 100));
        }
        if (spots.isNotEmpty) benchRaw[series] = spots;
      }
    }

    // Y range from the full (pre-downsampled) data so the plot never clips.
    var minV = double.infinity;
    var maxV = double.negativeInfinity;
    for (final p in rawPoints) {
      if (p.y < minV) minV = p.y;
      if (p.y > maxV) maxV = p.y;
    }
    for (final spots in benchRaw.values) {
      for (final s in spots) {
        if (s.y < minV) minV = s.y;
        if (s.y > maxV) maxV = s.y;
      }
    }
    if (rawPoints.isEmpty) minV = 0;
    if (rawPoints.isEmpty) maxV = 0;
    final span = maxV - minV;
    final pad = span == 0 ? maxV.abs() * 0.05 : span * 0.12;
    // "Nice" axis: a 1/2/5×10ⁿ step with labels aligned to it, so ticks are
    // always evenly spaced human-friendly values (3.0/3.1/3.2) instead of the
    // raw min/max fl_chart force-includes — which overlap on small ranges.
    final ticks = NiceAxis.ticks(minV - pad, maxV + pad);
    final axisMin = ticks.ticks.first;
    final axisMax = ticks.ticks.last;
    final longRange = list.length > 250;
    final dense = list.length > _denseThreshold;
    // Axis labels use the step's precision; the tooltip keeps 2 decimals.
    String pctLabel(double pctPoints, int decimals) {
      final rounded = double.parse(pctPoints.toStringAsFixed(decimals));
      final sign = rounded < 0 ? '-' : (rounded > 0 ? '+' : '');
      return '$sign${rounded.abs().toStringAsFixed(decimals)}%';
    }

    String valueText(double v) => isRate
        ? pctLabel(v, ticks.decimals)
        : hideAmounts
            ? Formats.masked()
            : Formats.amountCompact(v);
    String tooltipText(double v) => isRate
        ? '${v >= 0 ? '+' : ''}${Formats.pct(v / 100)}'
        : hideAmounts
            ? Formats.masked()
            : Formats.money(v);

    const ds = ChartDownsample();
    List<FlSpot> toSpots(List<ChartPoint> pts) =>
        [for (final p in pts) FlSpot(p.x, p.y)];
    final points = toSpots(ds.downsample(
      [for (final p in rawPoints) (x: p.x, y: p.y)],
    ));
    final benchSeries = <_BenchSeries, List<FlSpot>>{
      for (final entry in benchRaw.entries)
        entry.key: toSpots(ds.downsample(
          [for (final p in entry.value) (x: p.x, y: p.y)],
        )),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        // Date ticks: roughly one per 80px of plot width, at least 3.
        final plotWidth = (constraints.maxWidth - 48).clamp(0.0, double.infinity);
        final labelCount =
            (plotWidth / 80).floor().clamp(3, list.length.clamp(3, 12));
        final xInterval = (list.length / labelCount).ceilToDouble();
        return SizedBox(
          height: Responsive.isPhone(context) ? 280 : 240,
          child: LineChart(
            LineChartData(
              minY: axisMin,
              maxY: axisMax,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: ticks.step,
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
                    reservedSize: 48,
                    interval: ticks.step,
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
                    interval: xInterval,
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
                        '${tooltipText(spot.y)}',
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
                  // Dense series (downsampled) are drawn as straight segments;
                  // smoothing hundreds of points into a narrow plot creates
                  // loops and false detail. Short ranges keep the smooth curve.
                  isCurved: !dense,
                  curveSmoothness: 0.25,
                  color: color,
                  barWidth: dense ? 2 : 2.5,
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
                for (final entry in benchSeries.entries)
                  LineChartBarData(
                    spots: entry.value,
                    isCurved: !dense,
                    curveSmoothness: 0.25,
                    color: entry.key.color.withValues(alpha: 0.8),
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size(14, 3),
          painter: _LinePainter(color: color),
        ),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  const _LinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, Offset(size.width, 0), paint);
  }

  @override
  bool shouldRepaint(covariant _LinePainter oldDelegate) =>
      oldDelegate.color != color;
}
