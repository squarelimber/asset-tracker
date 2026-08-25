import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../domain/product_monthly_earnings.dart';

/// Per-product monthly earnings calendar: a month x product heatmap so the
/// best-performing product of each month is visible at a glance. Sold-out
/// products keep their full history (flow replay).
class ProductEarningsCalendarPage extends ConsumerStatefulWidget {
  const ProductEarningsCalendarPage({super.key});

  @override
  ConsumerState<ProductEarningsCalendarPage> createState() =>
      _ProductEarningsCalendarPageState();
}

enum _PEView { year, month }

enum _PEFilter { all, held }

class _ProductEarningsCalendarPageState
    extends ConsumerState<ProductEarningsCalendarPage> {
  late int _year;
  late int _month;
  _PEView _view = _PEView.year;
  _PEFilter _filter = _PEFilter.all;
  int _mobileMonths = 6;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  void _shiftYear(int delta) => setState(() => _year += delta);

  void _shiftMonth(int delta) {
    setState(() {
      final d = DateTime(_year, _month + delta, 1);
      _year = d.year;
      _month = d.month;
    });
  }

  void _openMonth(int month) => setState(() {
        _month = month;
        _view = _PEView.month;
      });

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productEarningsProvider(_year));
    return Scaffold(
      appBar: AppBar(title: const Text('产品收益日历')),
      body: products.when(
        data: (list) => _PEBody(
          products: list,
          year: _year,
          month: _month,
          view: _view,
          filter: _filter,
          mobileMonths: _mobileMonths,
          onShiftYear: _shiftYear,
          onShiftMonth: _shiftMonth,
          onOpenMonth: _openMonth,
          onViewChanged: (v) => setState(() => _view = v),
          onFilterChanged: (f) => setState(() => _filter = f),
          onMobileMonthsChanged: (n) => setState(() => _mobileMonths = n),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }
}

class _PEBody extends StatelessWidget {
  const _PEBody({
    required this.products,
    required this.year,
    required this.month,
    required this.view,
    required this.filter,
    required this.mobileMonths,
    required this.onShiftYear,
    required this.onShiftMonth,
    required this.onOpenMonth,
    required this.onViewChanged,
    required this.onFilterChanged,
    required this.onMobileMonthsChanged,
  });

  final List<ProductEarnings> products;
  final int year;
  final int month;
  final _PEView view;
  final _PEFilter filter;
  final int mobileMonths;
  final ValueChanged<int> onShiftYear;
  final ValueChanged<int> onShiftMonth;
  final ValueChanged<int> onOpenMonth;
  final ValueChanged<_PEView> onViewChanged;
  final ValueChanged<_PEFilter> onFilterChanged;
  final ValueChanged<int> onMobileMonthsChanged;

  List<ProductEarnings> get _filtered => filter == _PEFilter.all
      ? products
      : products.where((p) => !p.closed).toList();

  @override
  Widget build(BuildContext context) {
    final isPhone = Responsive.isPhone(context);
    final isYearView = view == _PEView.year;
    final calc = const ProductEarningsCalculator();

    final shownMonths =
        isYearView && isPhone ? _monthsWindow(mobileMonths) : _monthsWindow(12);

    // Year view: rows sorted by yearly rate (desc, nulls last).
    final rows = _filtered
        .map((p) => (p: p, months: calc.yearOf(p, year)))
        .toList()
      ..sort((a, b) {
        final ra = calc.yearlyRate(a.months, a.p, year);
        final rb = calc.yearlyRate(b.months, b.p, year);
        if (ra == null && rb == null) {
          return calc.yearlyProfit(b.months).compareTo(calc.yearlyProfit(a.months));
        }
        if (ra == null) return 1;
        if (rb == null) return -1;
        return rb.compareTo(ra);
      });

    // Month view: rows sorted by that month's rate (desc, nulls last).
    final monthRows = _filtered
        .map((p) => (p: p, m: calc.monthOf(p, year, month)))
        .where((r) => r.m.days > 0)
        .toList()
      ..sort((a, b) {
        if (a.m.rate == null && b.m.rate == null) {
          return b.m.profit.compareTo(a.m.profit);
        }
        if (a.m.rate == null) return 1;
        if (b.m.rate == null) return -1;
        return b.m.rate!.compareTo(a.m.rate!);
      });

    return ResponsiveShell(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            Center(
              child: SegmentedButton<_PEView>(
                segments: const [
                  ButtonSegment(value: _PEView.year, label: Text('年')),
                  ButtonSegment(value: _PEView.month, label: Text('月')),
                ],
                selected: {view},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onSelectionChanged: (s) => onViewChanged(s.first),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: isYearView ? '上一年' : '上一月',
                  icon: const Icon(Icons.chevron_left),
                  onPressed:
                      isYearView ? () => onShiftYear(-1) : () => onShiftMonth(-1),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      isYearView ? '$year年' : '$year年$month月',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: isYearView ? '下一年' : '下一月',
                  icon: const Icon(Icons.chevron_right),
                  onPressed:
                      isYearView ? () => onShiftYear(1) : () => onShiftMonth(1),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SegmentedButton<_PEFilter>(
                  segments: const [
                    ButtonSegment(value: _PEFilter.all, label: Text('全部')),
                    ButtonSegment(value: _PEFilter.held, label: Text('仅持有中')),
                  ],
                  selected: {filter},
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onSelectionChanged: (s) => onFilterChanged(s.first),
                ),
                if (isYearView && isPhone) ...[
                  const SizedBox(width: 12),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 6, label: Text('近6月')),
                      ButtonSegment(value: 12, label: Text('12月')),
                    ],
                    selected: {mobileMonths},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onSelectionChanged: (s) => onMobileMonthsChanged(s.first),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: isYearView
                  ? _YearMatrix(
                      rows: rows,
                      months: shownMonths,
                      year: year,
                      onTapMonth: onOpenMonth,
                    )
                  : SingleChildScrollView(
                      child: _MonthList(
                        rows: monthRows,
                        year: year,
                        month: month,
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            Text(
              '收益为成本法口径：已剔除申赎等本金进出影响；已清仓产品按流水回放保留完整历史，清仓月收益为已实现收益。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  List<int> _monthsWindow(int count) {
    final now = DateTime.now();
    if (year != now.year) return List.generate(12, (i) => i + 1);
    final start = math.max(1, now.month - count + 1);
    return List.generate(now.month - start + 1, (i) => start + i);
  }
}

/// Month x product heatmap for one year. The product-name column (left) and
/// the month header (top) stay pinned while the cells scroll in both axes;
/// the header and the grid follow the same horizontal offset.
class _YearMatrix extends StatefulWidget {
  const _YearMatrix({
    required this.rows,
    required this.months,
    required this.year,
    required this.onTapMonth,
  });

  final List<({ProductEarnings p, List<ProductMonthEarning> months})> rows;
  final List<int> months;
  final int year;
  final ValueChanged<int> onTapMonth;

  @override
  State<_YearMatrix> createState() => _YearMatrixState();
}

class _YearMatrixState extends State<_YearMatrix> {
  static const double _headerHeight = 24;
  static const double _rowHeight = 44;

  final ScrollController _headerCtrl = ScrollController();
  final ScrollController _bodyCtrl = ScrollController();
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _headerCtrl.addListener(() => _sync(_headerCtrl, _bodyCtrl));
    _bodyCtrl.addListener(() => _sync(_bodyCtrl, _headerCtrl));
  }

  void _sync(ScrollController src, ScrollController dst) {
    if (_syncing) return;
    if (src.positions.isEmpty || dst.positions.isEmpty) return;
    final s = src.positions.first;
    final d = dst.positions.first;
    if ((s.pixels - d.pixels).abs() < 0.5) return;
    _syncing = true;
    d.jumpTo(s.pixels);
    _syncing = false;
  }

  @override
  void dispose() {
    _headerCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calc = const ProductEarningsCalculator();
    final isPhone = Responsive.isPhone(context);

    // Best product per month (highest rate among products with data).
    final bestByMonth = <int, String>{};
    for (final m in widget.months) {
      double? bestRate;
      String? bestName;
      for (final row in widget.rows) {
        final agg = _aggOf(row, m);
        if (agg == null || agg.rate == null) continue;
        if (bestRate == null || agg.rate! > bestRate) {
          bestRate = agg.rate;
          bestName = row.p.name;
        }
      }
      if (bestName != null) bestByMonth[m] = bestName;
    }

    final nameWidth = isPhone ? 92.0 : 150.0;
    final colWidth = isPhone ? 52.0 : 64.0;
    final dividerColor = Theme.of(context).colorScheme.outlineVariant;

    final header = Row(
      children: [
        SizedBox(
          width: nameWidth,
          height: _headerHeight,
          child: Center(
            child: Text(
              '产品',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        Container(width: 1, height: _headerHeight, color: dividerColor),
        Expanded(
          child: SingleChildScrollView(
            controller: _headerCtrl,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final m in widget.months)
                  SizedBox(
                    width: colWidth,
                    child: Center(
                      child: Text(
                        '$m月',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                SizedBox(
                  width: colWidth,
                  child: Center(
                    child: Text(
                      '全年',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    final nameColumn = SizedBox(
      width: nameWidth,
      child: Column(
        children: [
          for (final row in widget.rows)
            SizedBox(
              height: _rowHeight,
              child: Center(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        row.p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    if (row.p.closed)
                      Container(
                        margin: const EdgeInsets.only(left: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '清仓',
                          style: TextStyle(
                            fontSize: 9,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    final gridRows = <Widget>[];
    for (final row in widget.rows) {
      final cells = <Widget>[];
      for (final m in widget.months) {
        final agg = _aggOf(row, m);
        cells.add(
          SizedBox(
            width: colWidth,
            child: _MatrixCell(
              agg: agg,
              isBest: agg != null && bestByMonth[m] == row.p.name,
              onTap: agg != null && agg.days > 0
                  ? () => widget.onTapMonth(m)
                  : null,
            ),
          ),
        );
      }
      cells.add(
        SizedBox(
          width: colWidth,
          child: _YearlyCell(
            profit: calc.yearlyProfit(row.months),
            rate: calc.yearlyRate(row.months, row.p, widget.year),
          ),
        ),
      );
      gridRows.add(SizedBox(height: _rowHeight, child: Row(children: cells)));
    }

    return Column(
      children: [
        header,
        Container(height: 1, color: dividerColor),
        Expanded(
          child: SingleChildScrollView(
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  nameColumn,
                  Container(width: 1, color: dividerColor),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _bodyCtrl,
                      scrollDirection: Axis.horizontal,
                      child: Column(children: gridRows),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  ProductMonthEarning? _aggOf(
      ({ProductEarnings p, List<ProductMonthEarning> months}) row, int month) {
    for (final m in row.months) {
      if (m.month == month) return m;
    }
    return null;
  }
}

class _MatrixCell extends StatelessWidget {
  const _MatrixCell({required this.agg, required this.isBest, this.onTap});

  final ProductMonthEarning? agg;
  final bool isBest;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasData = agg != null && agg!.days > 0;
    final rate = agg?.rate;
    final hasRate = hasData && rate != null;

    Color? bg;
    Color? fg;
    if (hasRate) {
      final up = rate >= 0;
      final intensity = math.min(0.28, (rate.abs() / 0.10) * 0.28);
      final base = up ? AppColors.up : AppColors.down;
      bg = base.withValues(alpha: intensity);
      fg = base;
    } else if (hasData) {
      fg = Theme.of(context).colorScheme.outline;
    }

    return Padding(
      padding: const EdgeInsets.all(2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          decoration: BoxDecoration(
            color: bg ??
                Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
            border: isBest
                ? Border.all(color: AppColors.primary, width: 1.6)
                : null,
          ),
          child: Stack(
            children: [
              Center(
                child: Text(
                  !hasData
                      ? '--'
                      : hasRate
                           ? '${rate >= 0 ? '+' : ''}${Formats.pct1(rate)}'
                          : '--',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: fg ?? Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
              if (agg?.closed == true)
                Positioned(
                  top: 0,
                  right: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 3, vertical: 0.5),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Text(
                      '清',
                      style: TextStyle(fontSize: 8, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _YearlyCell extends StatelessWidget {
  const _YearlyCell({required this.profit, required this.rate});

  final double profit;
  final double? rate;

  @override
  Widget build(BuildContext context) {
    final hasRate = rate != null;
    return Container(
      margin: const EdgeInsets.all(2),
      constraints: const BoxConstraints(minHeight: 40),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            hasRate
                ? '${rate! >= 0 ? '+' : ''}${Formats.pct1(rate!)}'
                : '--',
            maxLines: 1,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: hasRate
                  ? context.changeColor(rate!)
                  : Theme.of(context).colorScheme.outline,
            ),
          ),
          Text(
            Formats.amountCompact(profit),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-product rows for one month: rate, profit and a net-value sparkline.
class _MonthList extends StatelessWidget {
  const _MonthList({required this.rows, required this.year, required this.month});

  final List<({ProductEarnings p, ProductMonthEarning m})> rows;
  final int year;
  final int month;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              '本月暂无数据',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final row in rows)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                row.p.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            if (row.p.closed)
                              Container(
                                margin: const EdgeInsets.only(left: 6),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '清仓',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          row.m.rate == null
                              ? '收益率 --'
                              : '收益率 ${row.m.rate! >= 0 ? '+' : ''}${Formats.pct(row.m.rate!)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: row.m.rate == null
                                ? Theme.of(context).colorScheme.outline
                                : context.changeColor(row.m.rate!),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '收益 ${Formats.signedAmount(row.m.profit)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _Sparkline(
                    values: _netSeries(row.p),
                    color: context.changeColor(
                        _netSeries(row.p).isEmpty
                            ? 0
                            : _netSeries(row.p).last - _netSeries(row.p).first),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  List<double> _netSeries(ProductEarnings p) {
    final prefix = '$year-${month.toString().padLeft(2, '0')}';
    final nets = <double>[];
    double? prevNet;
    for (final d in p.daily) {
      if (!d.date.startsWith(prefix)) {
        if (d.date.compareTo(prefix) < 0) {
          prevNet = d.value - d.cost;
        }
        continue;
      }
      final net = d.value - d.cost;
      if (prevNet != null) nets.add(net - prevNet);
      prevNet = net;
    }
    return nets;
  }
}

/// Tiny polyline of the month's daily profits.
class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      height: 36,
      child: CustomPaint(painter: _SparklinePainter(values, color)),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) {
      canvas.drawLine(
        Offset(size.width / 2, size.height / 2),
        Offset(size.width / 2 + 6, size.height / 2),
        Paint()..color = color..strokeWidth = 1,
      );
      return;
    }
    var min = values.reduce(math.min);
    var max = values.reduce(math.max);
    final range = max - min;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = range <= 0
          ? size.height / 2
          : size.height * (1 - (values[i] - min) / range);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.color != color;
}
