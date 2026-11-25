import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/category_earnings_provider.dart';
import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../domain/category_earnings.dart';
import '../../components/app_bar_actions.dart';
import '../../components/earnings_issue_notice.dart';
import '../../components/error_state.dart';
import '../../components/secondary_page_back_button.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

enum _Period { month, year, custom }

class CategoryEarningsPage extends ConsumerStatefulWidget {
  const CategoryEarningsPage({super.key, this.initialCategory});

  final AssetCategory? initialCategory;

  @override
  ConsumerState<CategoryEarningsPage> createState() =>
      _CategoryEarningsPageState();
}

class _CategoryEarningsPageState extends ConsumerState<CategoryEarningsPage> {
  _Period _period = _Period.month;
  late DateTimeRange _dates;
  final _expanded = <AssetCategory>{};

  @override
  void initState() {
    super.initState();
    final now = DateUtils.dateOnly(DateTime.now());
    _dates = DateTimeRange(start: DateTime(now.year, now.month), end: now);
    if (widget.initialCategory case final category?) _expanded.add(category);
  }

  Future<void> _selectPeriod(_Period period) async {
    final today = DateUtils.dateOnly(DateTime.now());
    if (period == _Period.custom) {
      final selected = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1970),
        lastDate: today,
        initialDateRange: _dates,
        helpText: '选择收益区间',
        cancelText: '取消',
        confirmText: '确定',
        saveText: '确定',
        fieldStartLabelText: '开始日期',
        fieldEndLabelText: '结束日期',
        errorInvalidRangeText: '结束日期不能早于开始日期',
        builder: (context, child) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
            child: child,
          ),
        ),
      );
      if (!mounted || selected == null) return;
      setState(() {
        _period = period;
        _dates = selected;
      });
      return;
    }
    setState(() {
      _period = period;
      _dates = DateTimeRange(
        start: period == _Period.month
            ? DateTime(today.year, today.month)
            : DateTime(today.year),
        end: today,
      );
    });
  }

  void _retry(CategoryEarningsPeriod range) {
    ref.invalidate(snapshotsProvider);
    ref.invalidate(holdingsProvider);
    ref.invalidate(transactionsProvider);
    ref.invalidate(categoryEarningsProvider(range));
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(historySyncProvider);
    final range = (
      from: Formats.date(_dates.start),
      to: Formats.date(_dates.end),
    );
    final report = ref.watch(categoryEarningsProvider(range));
    final hidden = ref.watch(hideAmountsProvider);
    return Scaffold(
      appBar: AppBar(
        leading: const SecondaryPageBackButton(),
        title: const Text('分类收益'),
        actions: const [TerminalAppBarActions()],
      ),
      body: ResponsiveShell(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(historySyncProvider);
            _retry(range);
            try {
              await ref.read(categoryEarningsProvider(range).future);
            } catch (_) {
              // The provider renders the failure with a retry action.
            }
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Wrap(
                spacing: T.s2,
                runSpacing: T.s2,
                children: [
                  for (final period in _Period.values)
                    ChoiceChip(
                      key: ValueKey('category-period-${period.name}'),
                      label: Text(switch (period) {
                        _Period.month => '本月',
                        _Period.year => '今年',
                        _Period.custom => '自定义',
                      }),
                      selected: period == _period,
                      showCheckmark: false,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onSelected: (_) => _selectPeriod(period),
                    ),
                ],
              ),
              const SizedBox(height: T.s2),
              Text(
                '${range.from} 至 ${range.to}',
                style: T.mono(size: 12, color: T.text2),
              ),
              const SizedBox(height: T.s4),
              ...report.when(
                data: (value) => _reportWidgets(value, hidden),
                loading: () => const [
                  TerminalCard(
                    child: Padding(
                      padding: EdgeInsets.all(T.s5),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
                ],
                error: (_, _) => [
                  TerminalCard(
                    child: ErrorState(
                      message: '分类收益加载失败，请重试',
                      onRetry: () => _retry(range),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: T.s2),
              Text(
                '按当前资产分类汇总历史收益，修改分类后，历史收益也会重新归类。包含区间内已清仓或归档的产品。',
                style: T.label(),
              ),
              const SizedBox(height: T.s2),
              Text(
                '收益沿用收益日历的历史快照口径，剔除本金进出。收益率为区间收益除以期初市值；期初市值不大于零时显示 --。',
                style: T.label(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _reportWidgets(CategoryEarningsReport report, bool hidden) {
    if (!report.verified) {
      return [
        TerminalCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.info_outline, size: 20, color: T.warning),
                  SizedBox(width: T.s2),
                  Expanded(child: Text('该区间收益待核对')),
                ],
              ),
              const SizedBox(height: T.s2),
              Text('核对完成后可查看分类收益。', style: T.label()),
              for (final issue in report.issues) ...[
                const SizedBox(height: T.s3),
                EarningsIssueNotice(issue: issue),
              ],
            ],
          ),
        ),
      ];
    }
    if (report.isEmpty) {
      return [
        TerminalCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: T.s5),
            child: Column(
              children: [
                const Icon(Icons.bar_chart_outlined, size: 32, color: T.text3),
                const SizedBox(height: T.s3),
                const Text('该区间暂无收益快照'),
                const SizedBox(height: T.s2),
                Text(
                  '可以切换时间区间，或记录持仓后再来查看。',
                  style: T.label(),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ];
    }
    final categories = [...report.categories]
      ..sort((a, b) => b.profit.compareTo(a.profit));
    final initial = widget.initialCategory;
    if (initial != null) {
      final index = categories.indexWhere((entry) => entry.category == initial);
      if (index > 0) categories.insert(0, categories.removeAt(index));
    }
    final maximum = categories.fold(
      0.0,
      (value, row) => math.max(value, row.profit.abs()),
    );
    return [
      TerminalCard(
        padding: const EdgeInsets.all(T.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('区间收益', style: T.label(size: 12)),
            const SizedBox(height: T.s2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        hidden ? '****' : _money(report.totalProfit),
                        key: const ValueKey('category-summary-profit'),
                        style: T.mono(
                          size: 28,
                          weight: FontWeight.w600,
                          color: hidden
                              ? T.text1
                              : T.changeColor(report.totalProfit),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: T.s4),
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('区间收益率', style: T.label()),
                      const SizedBox(height: T.s1),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          hidden ? '****' : _rate(report.totalRate),
                          key: const ValueKey('category-summary-rate'),
                          style: T.mono(
                            size: 17,
                            color: hidden
                                ? T.text1
                                : T.changeColor(report.totalRate ?? 0),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: T.s3),
            Text(
              '${categories.length} 类资产 · ${report.days} 天快照记录',
              style: T.label(),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: T.s3),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '各类资产表现',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              initial == null ? '按收益金额排序' : '优先展示${initial.label}',
              style: T.label(),
            ),
          ],
        ),
      ),
      for (final entry in categories)
        _CategoryCard(
          entry: entry,
          hidden: hidden,
          maximum: maximum,
          expanded: _expanded.contains(entry.category),
          onToggle: () => setState(() {
            if (!_expanded.add(entry.category)) {
              _expanded.remove(entry.category);
            }
          }),
        ),
      if (categories.isEmpty) const TerminalCard(child: Text('该区间暂无可归类的资产收益')),
    ];
  }
}

String _money(double value) =>
    '${value >= 0 ? '+' : '-'}${Formats.money(value.abs())}';

String _rate(double? value) =>
    value == null ? '--' : '${value >= 0 ? '+' : ''}${Formats.pct(value)}';

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.entry,
    required this.hidden,
    required this.maximum,
    required this.expanded,
    required this.onToggle,
  });

  final CategoryEarning entry;
  final bool hidden;
  final double maximum;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final category = entry.category;
    final products = [...entry.products]
      ..sort((a, b) => b.profit.compareTo(a.profit));
    return TerminalCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              key: ValueKey('category-row-${category.storageName}'),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.all(T.s4),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(category.icon, size: 20, color: category.color),
                        const SizedBox(width: T.s3),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                category.label,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: T.s1),
                              Text('${products.length} 个产品', style: T.label()),
                            ],
                          ),
                        ),
                        const SizedBox(width: T.s2),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  hidden ? '****' : _money(entry.profit),
                                  style: T.mono(
                                    size: 17,
                                    weight: FontWeight.w600,
                                    color: hidden
                                        ? T.text1
                                        : T.changeColor(entry.profit),
                                  ),
                                ),
                              ),
                              const SizedBox(height: T.s1),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  hidden ? '****' : _rate(entry.rate),
                                  style: T.mono(size: 12, color: T.text2),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: T.s2),
                        Icon(
                          expanded ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                          color: T.text3,
                        ),
                      ],
                    ),
                    const SizedBox(height: T.s3),
                    if (!hidden)
                      _ProfitBar(
                        key: ValueKey(
                          'category-profit-bar-${category.storageName}',
                        ),
                        profit: entry.profit,
                        maximum: maximum,
                      )
                    else
                      const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Container(
              key: ValueKey('category-products-${category.storageName}'),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: T.borderSoft)),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: T.s4,
                vertical: T.s2,
              ),
              child: Column(
                children: [
                  for (var index = 0; index < products.length; index++) ...[
                    if (index > 0)
                      const Divider(height: 1, color: T.borderSoft),
                    _ProductRow(product: products[index], hidden: hidden),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.product, required this.hidden});

  final CategoryProductEarning product;
  final bool hidden;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: T.s3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(product.name, style: const TextStyle(fontSize: 12)),
              if (product.closed) ...[
                const SizedBox(height: T.s1),
                Text('期末已清仓', style: T.label(size: 10)),
              ],
            ],
          ),
        ),
        const SizedBox(width: T.s3),
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  hidden ? '****' : _money(product.profit),
                  style: T.mono(
                    size: 13,
                    color: hidden ? T.text1 : T.changeColor(product.profit),
                  ),
                ),
              ),
              const SizedBox(height: T.s1),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  hidden ? '****' : _rate(product.rate),
                  style: T.mono(size: 11, color: T.text2),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ProfitBar extends StatelessWidget {
  const _ProfitBar({super.key, required this.profit, required this.maximum});

  final double profit;
  final double maximum;

  @override
  Widget build(BuildContext context) {
    final fraction = maximum == 0
        ? 0.0
        : (profit.abs() / maximum).clamp(0.0, 1.0);
    Widget half(bool positive) => Expanded(
      child: Align(
        alignment: positive ? Alignment.centerLeft : Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: (positive ? profit > 0 : profit < 0) ? fraction : 0,
          child: ColoredBox(
            color: T.changeColor(profit),
            child: const SizedBox(height: 4),
          ),
        ),
      ),
    );
    return ExcludeSemantics(
      child: SizedBox(
        height: 6,
        child: Row(
          children: [
            half(false),
            const ColoredBox(
              color: T.border,
              child: SizedBox(width: 1, height: 6),
            ),
            half(true),
          ],
        ),
      ),
    );
  }
}
