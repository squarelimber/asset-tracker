import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../domain/product_monthly_earnings.dart';
import '../../components/app_bar_actions.dart';
import '../../components/sparkline.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

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
      appBar: AppBar(
        title: const Text('产品收益日历'),
        actions: const [TerminalAppBarActions()],
      ),
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
          const SizedBox(height: T.s3),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: isYearView ? '上一年' : '上一月',
                icon: const Icon(Icons.chevron_left),
                onPressed: isYearView ? () => onShiftYear(-1) : () => onShiftMonth(-1),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    isYearView ? '$year年' : '$year年$month月',
                    style: T.mono(size: 15, weight: FontWeight.w600),
                  ),
                ),
              ),
              IconButton(
                tooltip: isYearView ? '下一年' : '下一月',
                icon: const Icon(Icons.chevron_right),
                onPressed: isYearView ? () => onShiftYear(1) : () => onShiftMonth(1),
              ),
            ],
          ),
          const SizedBox(height: T.s2),
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
                const SizedBox(width: T.s3),
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
          const SizedBox(height: T.s3),
          Expanded(
            child: isYearView
                ? _YearMatrix(
                    rows: rows,
                    year: year,
                    requestedMonths: mobileMonths,
                    onTapMonth: onOpenMonth,
                  )
                : SingleChildScrollView(
                    child: _MonthList(rows: monthRows, year: year, month: month),
                  ),
          ),
          const SizedBox(height: T.s3),
          Text(
            '收益为成本法口径：已剔除申赎等本金进出影响；已清仓产品按流水回放保留完整历史，清仓月收益为已实现收益。',
            style: T.label(),
          ),
        ],
      ),
    );
  }
}

class _YearMatrix extends StatefulWidget {
  const _YearMatrix({
    required this.rows,
    required this.year,
    required this.requestedMonths,
    required this.onTapMonth,
  });

  final List<({ProductEarnings p, List<ProductMonthEarning> months})> rows;
  final int year;
  final int requestedMonths;
  final ValueChanged<int> onTapMonth;

  @override
  State<_YearMatrix> createState() => _YearMatrixState();
}

class _YearMatrixState extends State<_YearMatrix> {
  static const double _headerHeight = 28;
  static const double _rowHeight = 44;

  final ScrollController _hCtrl = ScrollController();

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPhone = Responsive.isPhone(context);
    final isTablet = Responsive.isTablet(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth;
        final nameWidth = isPhone ? 92.0 : (isTablet ? 120.0 : 150.0);
        final count = isPhone
            ? widget.requestedMonths
            : (isTablet
                ? ((contentWidth - nameWidth) / 12 >= 52 ? 12 : 6)
                : 12);
        final months = _monthsWindow(widget.year, count);
        final colWidth = isPhone
            ? 52.0
            : math.max(52.0, (contentWidth - nameWidth) / (months.length + 1));
        final showText = MediaQuery.sizeOf(context).width >= 360;
        final calc = const ProductEarningsCalculator();

        final bestByMonth = <int, String>{};
        for (final m in months) {
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

        final headerChild = Row(
          children: [
            SizedBox(
              width: nameWidth,
              height: _headerHeight,
              child: Center(child: Text('产品', style: T.label())),
            ),
            Container(width: 1, height: _headerHeight, color: T.border),
            Expanded(
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: _hCtrl,
                  builder: (context, _) => Transform.translate(
                    offset: Offset(-(_hCtrl.hasClients ? _hCtrl.offset : 0.0), 0),
                    child: SizedBox(
                      height: _headerHeight,
                      width: (months.length + 1) * colWidth,
                      child: Stack(
                        children: [
                          for (var i = 0; i < months.length; i++)
                            Positioned(
                              left: i * colWidth,
                              top: 0,
                              bottom: 0,
                              width: colWidth,
                              child: Center(
                                child: Text('${months[i]}月', style: T.label()),
                              ),
                            ),
                          Positioned(
                            left: months.length * colWidth,
                            top: 0,
                            bottom: 0,
                            width: colWidth,
                            child: Center(
                              child: Text(
                                '全年',
                                style: T.mono(
                                  size: 11,
                                  weight: FontWeight.w600,
                                  color: T.text2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
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
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: T.s2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: T.text1),
                          ),
                        ),
                        if (row.p.closed) const _ClosedBadge(),
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
          for (final m in months) {
            final agg = _aggOf(row, m);
            cells.add(
              SizedBox(
                width: colWidth,
                child: _MatrixCell(
                  agg: agg,
                  isBest: agg != null && bestByMonth[m] == row.p.name,
                  showText: showText,
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

        return CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: _HeaderDelegate(height: _headerHeight, child: headerChild),
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: 1, child: Container(color: T.border)),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: widget.rows.isEmpty ? 0 : widget.rows.length * _rowHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    nameColumn,
                    Container(width: 1, color: T.border),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _hCtrl,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: (months.length + 1) * colWidth,
                          height: widget.rows.length * _rowHeight,
                          child: Column(children: gridRows),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<int> _monthsWindow(int year, int count) {
    final now = DateTime.now();
    if (year != now.year) return List.generate(12, (i) => i + 1);
    final start = math.max(1, now.month - count + 1);
    return List.generate(now.month - start + 1, (i) => start + i);
  }

  ProductMonthEarning? _aggOf(
      ({ProductEarnings p, List<ProductMonthEarning> months}) row, int month) {
    for (final m in row.months) {
      if (m.month == month) return m;
    }
    return null;
  }
}

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  const _HeaderDelegate({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get maxExtent => height;

  @override
  double get minExtent => height;

  @override
  bool shouldRebuild(covariant _HeaderDelegate old) =>
      old.height != height || old.child != child;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) =>
      child;
}

class _MatrixCell extends StatelessWidget {
  const _MatrixCell({
    required this.agg,
    required this.isBest,
    required this.showText,
    this.onTap,
  });

  final ProductMonthEarning? agg;
  final bool isBest;
  final bool showText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasData = agg != null && agg!.days > 0;
    final rate = agg?.rate;
    final hasRate = hasData && rate != null;
    final profit = agg?.profit ?? 0;
    final hasProfit = hasData && profit != 0;
    final bg = hasRate
        ? T.heat(rate, -0.10, 0.10)
        : (hasData ? T.surface2 : T.surface);
    final fg = hasRate ? T.changeColor(rate) : T.text3;
    return Padding(
      padding: const EdgeInsets.all(T.s1),
      child: InkWell(
        borderRadius: BorderRadius.circular(T.rInput),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(T.rInput),
            border: isBest ? Border.all(color: T.accent, width: 1.6) : null,
          ),
          child: Stack(
            children: [
              Center(
                child: showText
                    ? Text(
                        !hasData
                            ? '--'
                            : hasProfit
                                ? '${profit >= 0 ? '+' : ''}${Formats.amountCompact(profit)}'
                                : '0',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.mono(
                          size: 10,
                          weight: FontWeight.w600,
                          color: fg,
                        ),
                      )
                    : Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: hasRate ? (rate >= 0 ? T.up : T.down) : T.text3,
                          shape: BoxShape.circle,
                        ),
                      ),
              ),
              if (agg?.closed == true)
                const Positioned(top: 0, right: 0, child: _ClosedBadge(compact: true)),
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
    return Padding(
      padding: const EdgeInsets.all(T.s1),
      child: Container(
        decoration: BoxDecoration(
          color: T.surface2,
          borderRadius: BorderRadius.circular(T.rInput),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              hasRate
                  ? '${rate! >= 0 ? '+' : ''}${Formats.pct1(rate!)}'
                  : '--',
              maxLines: 1,
              style: T.mono(
                size: 11,
                weight: FontWeight.w700,
                color: hasRate ? T.changeColor(rate!) : T.text3,
              ),
            ),
            Text(
              Formats.amountCompact(profit),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.mono(size: 10, color: T.text3),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClosedBadge extends StatelessWidget {
  const _ClosedBadge({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: T.s1),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 3 : T.s1,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: T.surface2,
        borderRadius: BorderRadius.circular(T.rInput),
        border: Border.all(color: T.border),
      ),
      child: Text(
        compact ? '清' : '清仓',
        style: TextStyle(fontSize: compact ? 8 : 9, color: T.text2),
      ),
    );
  }
}

class _MonthList extends StatelessWidget {
  const _MonthList({required this.rows, required this.year, required this.month});

  final List<({ProductEarnings p, ProductMonthEarning m})> rows;
  final int year;
  final int month;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const TerminalCard(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(T.s4),
            child: Text('本月暂无数据', style: TextStyle(color: T.text3)),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final row in rows)
          TerminalCard(
            margin: const EdgeInsets.only(bottom: T.s2),
            padding: const EdgeInsets.symmetric(horizontal: T.s3, vertical: T.s2),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              row.p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, color: T.text1),
                            ),
                          ),
                          if (row.p.closed) const _ClosedBadge(),
                        ],
                      ),
                      const SizedBox(height: T.s1),
                      Text(
                        row.m.rate == null
                            ? '收益率 --'
                            : '收益率 ${row.m.rate! >= 0 ? '+' : ''}${Formats.pct(row.m.rate!)}',
                        style: T.mono(
                          size: 12,
                          weight: FontWeight.w600,
                          color: row.m.rate == null
                              ? T.text3
                              : T.changeColor(row.m.rate!),
                        ),
                      ),
                      const SizedBox(height: T.s1),
                      Text(
                        '收益 ${Formats.signedAmount(row.m.profit)}',
                        style: T.mono(size: 11, color: T.text2),
                      ),
                    ],
                  ),
                ),
                Sparkline(
                  values: _netSeries(row.p),
                  color: T.changeColor(row.m.profit),
                  width: 84,
                  height: 36,
                ),
              ],
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
