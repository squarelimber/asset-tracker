import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../data/database.dart';
import '../../../domain/chart_downsample.dart';
import '../../../domain/nice_ticks.dart';
import '../../../domain/portfolio_calculator.dart';
import '../../../domain/range_stats.dart';
import '../../../domain/rate_series.dart';
import '../../../domain/target_allocation.dart';
import '../../../services/market/history_lookup.dart';
import '../../../services/market/history_source.dart';
import '../../../services/market/tencent_history_source.dart';
import '../../components/section_header.dart';
import '../../components/terminal_card.dart';
import '../../components/terminal_choice.dart';
import '../../tokens.dart';
import 'day_detail_sheet.dart';
import 'target_allocation_dialog.dart';

/// Asset allocation: donut + table (实际/目标/偏离), reference-mock layout.
class AllocationCard extends ConsumerWidget {
  const AllocationCard({super.key, required this.summary});

  final PortfolioSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(hideAmountsProvider);
    final breakdown = summary.breakdown.where((b) => b.marketValue > 0).toList()
      ..sort((a, b) => b.marketValue.compareTo(a.marketValue));
    if (breakdown.isEmpty) {
      return TerminalCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Expanded(child: SectionHeader(label: '资产配置')),
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => TargetAllocationDialog(summary: summary),
                ),
                child: const Text('调整目标'),
              ),
            ]),
            const Text('暂无资产配置数据', style: TextStyle(color: T.text3)),
          ],
        ),
      );
    }
    final total = summary.totalAssets;
    // Aggregate the fine-grained types into the high-level allocation
    // categories (股票/基金/黄金/债券/现金/其他) for the summary view.
    final byCat = <AssetCategory, double>{
      for (final b in summary.categoryBreakdown) b.category: b.marketValue,
    };
    final plan =
        ref.watch(targetAllocationProvider).value ??
        const <AssetCategory, double>{};
    final catEntries = [
      for (final entry in byCat.entries) (cat: entry.key, value: entry.value),
    ]..sort((a, b) => b.value.compareTo(a.value));

    // 偏离以「百分点」表述（42% − 40% = +2pp）。偏离由两个百分比相减
    // 得出，不涉及具体金额，因此不受「隐藏金额」开关影响——masked 后
    // 只剩红绿 '--' 反而比数字更暴露结构且无意义。
    String pp(double dev) {
      final rounded = (dev * 100).round();
      if (rounded == 0) return '0 pp';
      return '${rounded > 0 ? '+' : ''}$rounded pp';
    }

    final hasPlan = catEntries.any((e) => (plan[e.cat] ?? 0) > 0);
    final narrow = MediaQuery.sizeOf(context).width < 400;
    // 紧凑金额（表格列内使用，宽列时可读性优先）。
    String amountCompact(double v) =>
        hidden ? Formats.masked() : Formats.amountCompact(v);
    // 表格列宽：0=类别（贴内容，不让它吃掉剩余宽度造成松散），
    // 1=实际%，2=金额/目标，3=目标/偏离。窄屏把「金额」并入实际列
    // 下方小字，只保留 4 列。整表右对齐，与环形图形成「左图右数」。
    final colWidths = <int, TableColumnWidth>{
      0: const IntrinsicColumnWidth(),
      1: narrow ? const FixedColumnWidth(46) : const FixedColumnWidth(38),
      2: narrow ? const FixedColumnWidth(32) : const FixedColumnWidth(64),
      3: narrow ? const FixedColumnWidth(42) : const FixedColumnWidth(32),
      if (!narrow) 4: const FixedColumnWidth(42),
    };

    return TerminalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(child: SectionHeader(label: '资产配置')),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TargetAllocationDialog(summary: summary),
              ),
              child: const Text('调整目标'),
            ),
          ]),
          const SizedBox(height: T.s2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 左：环形图（中心显示总资产）。窄屏缩一号避免挤压表格；
              // 与右侧表格垂直居中对齐。
              SizedBox(
                width: narrow ? 116 : 148,
                height: narrow ? 116 : 148,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(
                      PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 44,
                        startDegreeOffset: -90,
                        sections: [
                          for (final e in catEntries)
                            PieChartSectionData(
                              value: e.value,
                              color: e.cat.color,
                              radius: 14,
                              showTitle: false,
                            ),
                        ],
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('资产类别', style: T.label(color: T.text3)),
                        const SizedBox(height: 2),
                        Text(
                          '${catEntries.length} 类',
                          style: T.mono(
                            size: narrow ? 13 : 15,
                            weight: FontWeight.w700,
                            color: T.text1,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: T.s2),
              // 右：Table 布局（表头与数据行列宽固定对齐，不错位）。
              // 整表贴右缘：类别列贴内容宽度，数字列与表头严格成列。
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Table(
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    columnWidths: colWidths,
                    children: [
                      // 表头（第一列留空对齐类别）。
                      TableRow(
                        children: [
                          const Text(''),
                          Text(
                            '实际',
                            textAlign: TextAlign.end,
                            style: T.label(color: T.text3),
                          ),
                          if (!narrow)
                            Text(
                              '金额',
                              textAlign: TextAlign.end,
                              style: T.label(color: T.text3),
                            ),
                          Text(
                            '目标',
                            textAlign: TextAlign.end,
                            style: T.label(color: T.text3),
                          ),
                          Text(
                            '偏离',
                            textAlign: TextAlign.end,
                            style: T.label(color: T.text3),
                          ),
                        ],
                      ),
                      for (final e in catEntries)
                        TableRow(
                          children: [
                            // 类别（色点 + 名称）。
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: e.cat.color,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    e.cat.label,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: T.text1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // 实际列：% 上、金额折行下（窄屏）；宽屏换紧凑金额。
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: narrow
                                  ? Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          total == 0
                                              ? '--'
                                              : Formats.pct0(e.value / total),
                                          style: T.mono(
                                            size: 12,
                                            color: T.text2,
                                          ),
                                        ),
                                        // 隐藏金额时显示掩码占位，保留
                                        // 行高与对齐（不留空变形）。
                                        Text(
                                          amountCompact(e.value),
                                          style: T.mono(
                                            size: 9,
                                            color: T.text3,
                                          ),
                                        ),
                                      ],
                                    )
                                  : Text(
                                      total == 0
                                          ? '--'
                                          : Formats.pct0(e.value / total),
                                      textAlign: TextAlign.end,
                                      style: T.mono(size: 12, color: T.text2),
                                    ),
                            ),
                            if (!narrow)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Text(
                                  amountCompact(e.value),
                                  textAlign: TextAlign.end,
                                  style: T.mono(size: 11, color: T.text3),
                                ),
                              ),
                            // 目标%：计划启用后每类都显示 —— 计划里没写的类按 0% 处理
                            //（「不该持有」也是明确目标，超配照常提醒）。
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                hasPlan
                                    ? Formats.pct0((plan[e.cat] ?? 0) / 100)
                                    : '--',
                                textAlign: TextAlign.end,
                                style: T.mono(size: 12, color: T.text2),
                              ),
                            ),
                            // 偏离 pp：超配红 / 低配绿 / 无计划灰。
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                hasPlan && total > 0
                                    ? pp(
                                        e.value / total -
                                            (plan[e.cat] ?? 0) / 100,
                                      )
                                    : '',
                                textAlign: TextAlign.end,
                                style: T.mono(
                                  size: 11,
                                  weight: FontWeight.w600,
                                  color: _devColor(
                                    e.value / total - (plan[e.cat] ?? 0) / 100,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 偏离着色：超配（实际 > 目标）红、低配绿、±0.5pp 内视为持平灰。
  static Color _devColor(double dev) {
    if (dev > 0.005) return T.up;
    if (dev < -0.005) return T.down;
    return T.text3;
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
  // 默认净资产视图（参考图：净资产 pill 选中）。
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

  /// 某个已选指数在当前区间（[list] 首末快照）内的累计收益率小标签，
  /// 颜色沿用指数曲线色；数据缺失时返回空。
  Widget _benchRangePct(String code, List<SnapshotRow> list) {
    final lookup = _benchData[code];
    if (lookup == null || list.isEmpty) return const SizedBox.shrink();
    final idx = _benchIndexes.firstWhere((b) => b.code == code);
    final first = lookup.priceOnOrBefore(list.first.date);
    final last = lookup.priceOnOrBefore(list.last.date);
    if (first == null || last == null || first <= 0) {
      return const SizedBox.shrink();
    }
    final pct = (last / first - 1) * 100;
    return Text(
      '${idx.label} ${pct >= 0 ? '+' : ''}${Formats.pct(pct / 100)}',
      style: T.mono(size: 10, color: idx.color),
    );
  }

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
                const Text(
                  '对比指数（收益率视图下叠加显示）',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: T.text1,
                  ),
                ),
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
                            const SnackBar(content: Text('最多同时对比 3 个指数')),
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

  Widget _viewToggle() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final view in _TrendView.values)
        TerminalChoice(
          label: view == _TrendView.returnRate ? '收益率' : '净值',
          selected: _view == view,
          onPressed: () => setState(() => _view = view),
        ),
    ],
  );

  Widget _rangeChip(
    RangeOption opt, {
    bool custom = false,
    VoidCallback? onCustomTap,
  }) {
    final selected = custom ? _range == RangeOption.custom : _range == opt;
    return TerminalChoice(
      label: custom
          ? (selected
                ? '自定义: ${Formats.date(_customFrom ?? DateTime.now()).substring(5)}'
                : '自定义')
          : opt.label,
      selected: selected,
      onPressed: custom
          ? (onCustomTap ?? _showRangeMenu)
          : () => setState(() => _range = opt),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshots = ref.watch(snapshotsProvider);
    // 内凹嵌入式面板（v0.10.3 设计更新）。
    final benchmarkChip = FilterChip(
      label: Text(
        _benchSelected.isEmpty ? '指数对比' : '指数对比(${_benchSelected.length})',
      ),
      selected: _benchSelected.isNotEmpty,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => _showBenchmarkPanel(),
    );
    return _InsetPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部行：指数对比（左）+ 视图切换 收益率/净值（右），相对面板顶部
          // 稍下沉、与下方内容紧凑。
          Padding(
            padding: const EdgeInsets.only(top: T.s1),
            child: Row(
              children: [benchmarkChip, const Spacer(), _viewToggle()],
            ),
          ),
          const SizedBox(height: 8),
          if (_range == RangeOption.custom && _customFrom != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${Formats.date(_customFrom!)} ~ ${Formats.date(_customTo ?? DateTime.now())}',
                style: T.mono(size: 11, color: T.text2),
              ),
            ),
          if (_range == RangeOption.all)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '全部历史',
                style: TextStyle(fontSize: 11, color: T.text2),
              ),
            ),
          const SizedBox(height: 4),
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
                  child: Center(
                    child: Text(
                      '暂无净值数据，每日打开 App 自动记录',
                      style: TextStyle(color: T.text3),
                    ),
                  ),
                );
              }
              final stats = const RangeStatsCalculator().compute(list);
              final isRate = _view == _TrendView.returnRate;
              final rates = const RateSeriesCalculator().ratesOf(list);
              final rateDelta = const RateSeriesCalculator().rangeRatePct(list);
              final rateAnnualized = const RateSeriesCalculator()
                  .annualizedFromRange(list);
              final mainValue = isRate
                  ? (rateDelta ?? 0)
                  : (stats?.profit ?? 0);
              final mainPct = isRate
                  ? (rateDelta ?? 0) / 100
                  : (stats?.profitPct ?? 0);
              final color = T.changeColor(mainValue);
              final hideAmounts = ref.watch(hideAmountsProvider);
              String moneyText(double v) =>
                  hideAmounts ? Formats.masked() : Formats.money(v);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_range == RangeOption.custom && _customFrom != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '${Formats.date(_customFrom!)} ~ ${Formats.date(_customTo ?? DateTime.now())}',
                        style: T.mono(size: 11, color: T.text2),
                      ),
                    ),
                  if (_range == RangeOption.all)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '全部历史',
                        style: TextStyle(fontSize: 11, color: T.text2),
                      ),
                    ),
                  const SizedBox(height: 4),
                  if (stats != null) ...[
                    // 布局：左侧纵向说明（区间收益 → 年化/天数），右侧主金额
                    // 右对齐，与趋势图右缘对齐；ⓘ 挂在收益率旁。
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // 左列：区间收益说明（纵向）
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    isRate ? '区间收益' : '区间年化',
                                    style: T.mono(size: 11, color: T.text3),
                                  ),
                                  const SizedBox(width: 4),
                                  Tooltip(
                                    message:
                                        '收益率自区间首日归零，与指数同起点对比；'
                                        '已剔除转入资金影响（成本口径近似）',
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(
                                        T.rPill,
                                      ),
                                      onTap: () => showDialog<void>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('收益率口径'),
                                          content: const Text(
                                            '收益率自区间首日归零，与指数同起点对比；'
                                            '已剔除转入资金影响（成本口径近似）',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: const Text('知道了'),
                                            ),
                                          ],
                                        ),
                                      ),
                                      child: const Padding(
                                        padding: EdgeInsets.all(2),
                                        child: Icon(
                                          Icons.info_outline,
                                          size: 13,
                                          color: T.text3,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                isRate
                                    ? '年化 ${rateAnnualized == null ? '--' : Formats.pct(rateAnnualized)}'
                                          ' · ${stats.days} 天'
                                    : '${stats.days} 天',
                                style: T.mono(size: 11, color: T.text3),
                              ),
                              // 方案①：已选指数的区间收益率（与资产同区间、
                              // 同起点），一眼对比「我的收益率 vs 指数」。
                              if (_benchSelected.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Wrap(
                                    spacing: 10,
                                    runSpacing: 2,
                                    children: [
                                      for (final code in _benchSelected)
                                        if (_benchData.containsKey(code))
                                          _benchRangePct(code, list),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 右列：主数值 + 次级小字，右对齐趋势图右缘
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isRate
                                  ? '${mainValue >= 0 ? '+' : ''}${Formats.pct(mainPct)}'
                                  : '${mainValue >= 0 ? '+' : ''}${moneyText(mainValue)}',
                              style: T.mono(
                                size: 22,
                                weight: FontWeight.w700,
                                color: color,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              isRate
                                  ? '${stats.profit >= 0 ? '+' : ''}${moneyText(stats.profit)}'
                                  : '${stats.profitPct >= 0 ? '+' : ''}${Formats.pct(stats.profitPct)}',
                              style: T.mono(
                                size: 12,
                                color: isRate ? T.text2 : color,
                              ),
                            ),
                          ],
                        ),
                      ],
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
                          _LegendDot(gradient: T.trendGradient, label: '资产'),
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
                  // 时间区段贴图表下方：强制单行（自定义在近3年右侧），放不下时
                  // 整体等比缩小（FittedBox scaleDown），不换行也不横向拖动。
                  const SizedBox(height: 6),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        for (final opt in _rangeOptions) ...[
                          _rangeChip(opt),
                          const SizedBox(width: 5),
                        ],
                        _rangeChip(
                          RangeOption.all,
                          custom: true,
                          onCustomTap: _showRangeMenu,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
            loading: () => const SizedBox(
              height: 220,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('净值数据加载失败', style: T.mono(size: 12, color: T.text2)),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => ref.invalidate(snapshotsProvider),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ],
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

/// One benchmark index overlay series.
class _BenchSeries {
  const _BenchSeries({
    required this.name,
    required this.color,
    required this.lookup,
  });

  final String name;
  final Color color;
  final HistoryPriceLookup lookup;
}

class _TrendChart extends StatefulWidget {
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

  @override
  State<_TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<_TrendChart> {
  final _hoverIndex = ValueNotifier<int?>(null);

  @override
  void dispose() {
    _hoverIndex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.list;
    final view = widget.view;
    final rates = widget.rates;
    final hideAmounts = widget.hideAmounts;

    // Keep measurements neutral; P&L readouts carry red/green semantics.
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
      for (final entry in widget.benchmarks.entries) {
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
    const ds = ChartDownsample();
    List<FlSpot> toSpots(List<ChartPoint> pts) => [
      for (final p in pts) FlSpot(p.x, p.y),
    ];
    final points = toSpots(
      ds.downsample([for (final p in rawPoints) (x: p.x, y: p.y)]),
    );
    final benchSeries = <_BenchSeries, List<FlSpot>>{
      for (final entry in benchRaw.entries)
        entry.key: toSpots(
          ds.downsample([for (final p in entry.value) (x: p.x, y: p.y)]),
        ),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        // Date ticks: roughly one per 80px of plot width, at least 3.
        // plotLeft must stay in sync with the leftTitles reservedSize below.
        // On a phone the Y gutter is sized to the widest tick label (measured
        // with the real font) instead of a fixed 48px, so the plot starts as
        // far left as the labels allow and the display area grows. Desktop
        // keeps a fixed comfortable 48px gutter.
        final isPhone = Responsive.isPhone(context);
        final yLabelSize = isPhone ? 8.0 : 10.0;
        late final double plotLeft;
        if (!isPhone) {
          plotLeft = 48.0;
        } else {
          final labelStyle = T.mono(size: yLabelSize, color: T.text3);
          final tp = TextPainter(textDirection: TextDirection.ltr);
          var widest = 0.0;
          for (final tick in ticks.ticks) {
            tp.text = TextSpan(text: valueText(tick), style: labelStyle);
            tp.layout();
            if (tp.width > widest) widest = tp.width;
          }
          // 22px floor keeps a readable gap even for tiny labels; the 44px
          // cap prevents an oversized tick from eating the whole card.
          plotLeft = (widest + 3.0).clamp(22.0, 44.0);
        }
        const plotBottom = 24.0;
        final plotWidth = (constraints.maxWidth - plotLeft).clamp(
          0.0,
          double.infinity,
        );
        final labelCount = (plotWidth / 110).floor().clamp(
          3,
          list.length.clamp(3, 10),
        );
        final xInterval = (list.length / labelCount).ceilToDouble();
        // 横向优先：趋势图的价值在于横向长度，纵向保持紧凑（扁矩形）。
        // 手机 ~150px、桌面 ~210px 高度，配合窄 Y 刻度让「长」感更突出。
        final chartHeight = isPhone ? 150.0 : 210.0;
        final plotSize = Size(
          (constraints.maxWidth - plotLeft).clamp(0.0, double.infinity),
          (chartHeight - plotBottom).clamp(0.0, double.infinity),
        );
        final lastValue = isRate
            ? (rates.isEmpty ? 0.0 : rates.last - rateBase)
            : list.last.totalValue;

        // 区间/视图切换时图表渐显（克制：250ms 淡入）。
        return AnimatedSwitcher(
          key: ValueKey(
            '${widget.view.name}-${widget.list.length}-'
            '${widget.list.isEmpty ? 0 : widget.list.last.date}',
          ),
          duration: const Duration(milliseconds: 250),
          switchInCurve: Curves.easeOut,
          child: SizedBox(
            height: chartHeight,
            child: Stack(
              children: [
                LineChart(
                  LineChartData(
                    minY: axisMin,
                    maxY: axisMax,
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: ticks.step,
                      getDrawingHorizontalLine: (v) => FlLine(
                        color: T.borderSoft,
                        strokeWidth: 1,
                        dashArray: const [4, 4],
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    titlesData: FlTitlesData(
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: plotLeft,
                          interval: ticks.step,
                          // Right-align labels inside the reserved gutter so
                          // they sit flush against the plot edge — the first
                          // data point then starts right at the axis instead of
                          // floating in a blank gap. The minimum tick gets extra
                          // bottom padding so it clears the X-axis date label
                          // (左下角 -4% 与 1月 不再贴紧).
                          getTitlesWidget: (v, meta) {
                            final isMin = (v - axisMin).abs() < ticks.step / 2;
                            return Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: EdgeInsets.only(
                                  bottom: isMin ? 10 : 0,
                                ),
                                child: Text(
                                  valueText(v),
                                  style: T.mono(
                                    size: yLabelSize,
                                    color: T.text3,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          interval: xInterval,
                          reservedSize: 24,
                          getTitlesWidget: (v, meta) {
                            final i = v.toInt();
                            if (i < 0 || i >= list.length) {
                              return const SizedBox.shrink();
                            }
                            final d = DateTime.tryParse(list[i].date);
                            if (d == null) return const SizedBox.shrink();
                            // 长区间用「M」或「yy/M」压缩标签，避免标签宽度
                            // 撞到 Y 轴；短区间用「M-d」。
                            final label = longRange
                                ? (list.length > 600
                                      ? '${d.year % 100}/${d.month}'
                                      : '${d.month}月')
                                : '${d.month}-${d.day}';
                            // 首/尾标签缩进，避免贴住 Y 轴刻度和右缘。
                            final leftPad = i == 0 ? 8.0 : 0.0;
                            return Padding(
                              padding: EdgeInsets.only(left: leftPad),
                              child: Text(
                                label,
                                style: T.mono(size: 10, color: T.text3),
                              ),
                            );
                          },
                        ),
                      ),
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                    ),
                    lineTouchData: LineTouchData(
                      // The custom overlay below owns the crosshair and label.
                      // Keep the touch callback without drawing a second tooltip.
                      handleBuiltInTouches: false,
                      touchCallback: (event, response) {
                        // Lines can be sampled at different dates and sorted
                        // by touch distance. The overlay describes the asset,
                        // so never use a benchmark's point as its date.
                        final idx = trendAssetSpotIndex(response?.lineBarSpots);
                        final ended = event is FlPanEndEvent ||
                            event is FlPanCancelEvent ||
                            event is FlPointerExitEvent ||
                            event is FlTapCancelEvent;
                        if (!ended && idx != null && idx >= 0 && idx < list.length) {
                          _hoverIndex.value = idx;
                        } else {
                          _hoverIndex.value = null;
                        }

                        if (event is FlTapUpEvent && idx != null &&
                            idx >= 0 && idx < list.length) {
                          widget.onDayTap?.call(list[idx].date);
                        }
                      },
                    ),
                    lineBarsData: [
                      LineChartBarData(
                        spots: points,
                        isCurved: false,
                        color: T.trendFrom,
                        barWidth: 1.6,
                        dotData: const FlDotData(show: false),
                        belowBarData: BarAreaData(
                          show: true,
                          gradient: T.trendAreaGradient,
                        ),
                      ),
                      for (final entry in benchSeries.entries)
                        LineChartBarData(
                          spots: entry.value,
                          isCurved: false,
                          curveSmoothness: 0.25,
                          color: entry.key.color.withValues(alpha: 0.8),
                          barWidth: 1.5,
                          dotData: const FlDotData(show: false),
                        ),
                    ],
                  ),
                ),
                if (points.isNotEmpty)
                  Positioned(
                    left: plotLeft,
                    top: 0,
                    width: plotSize.width,
                    height: plotSize.height,
                    child: IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _hoverIndex,
                        builder: (context, _) => CustomPaint(
                          size: plotSize,
                          painter: _TrendOverlayPainter(
                            hoverIndex: _hoverIndex.value,
                            list: list,
                            view: view,
                            rates: rates,
                            axisMin: axisMin,
                            axisMax: axisMax,
                            firstX: points.first.x,
                            xSpan: points.last.x - points.first.x,
                            lastX: points.last.x,
                            lastValue: lastValue,
                            hideAmounts: hideAmounts,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The chart's first line is the portfolio; benchmark spots may sort first.
int? trendAssetSpotIndex(List<LineBarSpot>? spots) {
  if (spots == null) return null;
  for (final spot in spots) {
    if (spot.barIndex == 0) return spot.x.toInt();
  }
  return null;
}

/// 走势图悬停/按压时的信息标签行：[日期, 数值, 较上次快照?]。
/// 数值口径与图表一致：净值模式显示金额（隐私掩码生效），收益率模式
/// 显示区间涨跌幅百分比；资产变化为相邻快照的总资产差额，可能包含资金进出。
List<String> trendHoverLabelLines({
  required List<SnapshotRow> list,
  required bool isRate,
  required List<double> rates,
  required int index,
  required bool hideAmounts,
}) {
  if (index < 0 || index >= list.length) return const [];
  final row = list[index];
  final date = DateTime.tryParse(row.date);
  final lines = <String>[date == null ? row.date : Formats.date(date)];
  if (isRate) {
    final rate = index < rates.length ? rates[index] - rates.first : null;
    lines.add(
      rate == null ? '--' : '${rate >= 0 ? '+' : ''}${Formats.pct(rate / 100)}',
    );
  } else {
    lines.add(hideAmounts ? Formats.masked() : Formats.money(row.totalValue));
  }
  if (index > 0) {
    final delta = isRate
        ? (index < rates.length && index - 1 < rates.length
              ? rates[index] - rates[index - 1]
              : null)
        : (row.totalValue + row.liabilities) -
              (list[index - 1].totalValue + list[index - 1].liabilities);
    if (delta != null) {
      final text = isRate
          ? '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(2)} 个百分点'
          : hideAmounts
          ? Formats.masked()
          : '${delta >= 0 ? '+' : ''}${Formats.money(delta)}';
      lines.add('${isRate ? '较上次' : '资产较上次'} $text');
    }
  }
  return lines;
}

class _TrendOverlayPainter extends CustomPainter {
  const _TrendOverlayPainter({
    required this.hoverIndex,
    required this.list,
    required this.view,
    required this.rates,
    required this.axisMin,
    required this.axisMax,
    required this.firstX,
    required this.xSpan,
    required this.lastX,
    required this.lastValue,
    required this.hideAmounts,
  });

  final int? hoverIndex;
  final List<SnapshotRow> list;
  final _TrendView view;
  final List<double> rates;
  final double axisMin;
  final double axisMax;
  final double firstX;
  final double xSpan;
  final double lastX;
  final double lastValue;
  final bool hideAmounts;

  @override
  void paint(Canvas canvas, Size size) {
    final ySpan = axisMax - axisMin;
    if (ySpan == 0 || xSpan <= 0) return;

    double xOf(double x) => ((x - firstX) / xSpan).clamp(0.0, 1.0) * size.width;
    double yOf(double value) =>
        (1 - (value - axisMin) / ySpan).clamp(0.0, 1.0) * size.height;

    final lastPoint = Offset(xOf(lastX), yOf(lastValue));
    // Static last observation; crosshairs appear only on interaction.
    canvas.drawCircle(
      lastPoint,
      3,
      Paint()..color = T.trendTo.withValues(alpha: 0.9),
    );
    final idx = hoverIndex;
    if (idx == null || idx < 0 || idx >= list.length) return;
    final isRate = view == _TrendView.returnRate;
    final rateBase = isRate && rates.isNotEmpty ? rates.first : 0.0;
    final value = isRate ? rates[idx] - rateBase : list[idx].totalValue;

    final paint = Paint()
      ..color = T.text3.withValues(alpha: 0.5)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final x = xOf(idx.toDouble());
    final y = yOf(value);
    _dashedLine(canvas, Offset(0, y), Offset(size.width, y), paint);
    _dashedLine(canvas, Offset(x, 0), Offset(x, size.height), paint);

    _drawHoverLabel(
      canvas,
      size,
      lines: trendHoverLabelLines(
        list: list,
        isRate: isRate,
        rates: rates,
        index: idx,
        hideAmounts: hideAmounts,
      ),
      anchorX: x,
      deltaValue: hideAmounts
          ? null
          : isRate
          ? (idx > 0 && idx < rates.length ? rates[idx] - rates[idx - 1] : null)
          : (idx > 0
                ? (list[idx].totalValue + list[idx].liabilities) -
                      (list[idx - 1].totalValue + list[idx - 1].liabilities)
                : null),
    );
  }

  /// 悬停/按压信息块：日期、数值、较上次快照。
  void _drawHoverLabel(
    Canvas canvas,
    Size size, {
    required List<String> lines,
    required double anchorX,
    double? deltaValue,
  }) {
    if (lines.isEmpty) return;
    final painters = <TextPainter>[];
    var widest = 0.0;
    for (final line in lines) {
      final tp = TextPainter(
        text: TextSpan(text: line, style: T.mono(size: 11)),
        textDirection: TextDirection.ltr,
      )..layout();
      painters.add(tp);
      if (tp.width > widest) widest = tp.width;
    }
    const padX = 8.0;
    const padY = 5.0;
    const lineH = 15.0;
    final boxW = widest + padX * 2;
    final boxH = padY * 2 + lines.length * lineH;
    // 优先放在锚点右侧；放不下则左侧，并夹在绘图区内。
    var left = anchorX + 10;
    if (left + boxW > size.width) left = anchorX - 10 - boxW;
    if (left < 0) left = 2;
    if (left + boxW > size.width) left = size.width - boxW - 2;
    const top = 6.0;
    final rect = Rect.fromLTWH(left, top, boxW, boxH);
    final bg = Paint()..color = T.surface2.withValues(alpha: 0.96);
    final border = Paint()
      ..color = T.border
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.drawRRect(rr, bg);
    canvas.drawRRect(rr, border);

    var y = top + padY;
    for (var i = 0; i < painters.length; i++) {
      final color = switch (i) {
        0 => T.text2,
        1 => T.text1,
        _ => deltaValue == null ? T.text2 : T.changeColor(deltaValue),
      };
      painters[i].text = TextSpan(
        text: lines[i],
        style: T.mono(size: 11, color: color),
      );
      painters[i].layout();
      painters[i].paint(canvas, Offset(left + padX, y));
      y += lineH;
    }
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    final delta = b - a;
    final dist = delta.distance;
    if (dist == 0) return;
    final dir = Offset(delta.dx / dist, delta.dy / dist);
    const dash = 4.0;
    const gap = 4.0;
    for (var t = 0.0; t < dist; t += dash + gap) {
      final end = (t + dash).clamp(0.0, dist);
      canvas.drawLine(a + dir * t, a + dir * end, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TrendOverlayPainter old) =>
      old.hoverIndex != hoverIndex ||
      old.list != list ||
      old.view != view ||
      old.rates != rates ||
      old.axisMin != axisMin ||
      old.axisMax != axisMax ||
      old.firstX != firstX ||
      old.xSpan != xSpan ||
      old.lastX != lastX ||
      old.lastValue != lastValue ||
      old.hideAmounts != hideAmounts;
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({this.color, this.gradient, required this.label})
    : assert(color != null || gradient != null, '图例需要颜色或渐变');

  /// 纯色图例（指数对比线）用这个；[gradient] 给渐变曲线用（资产）。
  final Color? color;
  final Gradient? gradient;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size(14, 3),
          painter: _LinePainter(color: color, gradient: gradient),
        ),
        const SizedBox(width: 5),
        Text(label, style: T.mono(size: 11, color: T.text2)),
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  const _LinePainter({this.color, this.gradient});

  final Color? color;
  final Gradient? gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color ?? Colors.transparent
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    // 图例小横线也要能表现渐变，否则「资产」只是个纯色点，和曲线对不上。
    final g = gradient;
    if (g != null) paint.shader = g.createShader(Offset.zero & size);
    canvas.drawLine(Offset.zero, Offset(size.width, 0), paint);
  }

  @override
  bool shouldRepaint(covariant _LinePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.gradient != gradient;
}

/// Chart panel shares the same surface and border as the other data panels.
class _InsetPanel extends StatelessWidget {
  const _InsetPanel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    decoration: BoxDecoration(
      color: T.surface,
      borderRadius: BorderRadius.circular(T.rCard),
      border: Border.all(color: T.border),
    ),
    child: child,
  );
}
