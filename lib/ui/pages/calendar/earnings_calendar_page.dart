import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../domain/daily_earnings.dart';
import '../../components/app_bar_actions.dart';
import '../../components/heat_cell.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';
import '../portfolio/day_detail_sheet.dart';

final earningsProvider = FutureProvider<List<DailyEarning>>((ref) async {
  final snapshots = ref.watch(snapshotsProvider).value ?? const [];
  return const DailyEarningsCalculator().compute(snapshots);
});

class EarningsCalendarPage extends ConsumerStatefulWidget {
  const EarningsCalendarPage({super.key});

  @override
  ConsumerState<EarningsCalendarPage> createState() => _EarningsCalendarPageState();
}

enum _CalView { month, year }

class _EarningsCalendarPageState extends ConsumerState<EarningsCalendarPage> {
  final _calc = const DailyEarningsCalculator();
  late int _year;
  late int _month;
  _CalView _view = _CalView.month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  @override
  Widget build(BuildContext context) {
    final earnings = ref.watch(earningsProvider);
    ref.watch(historySyncProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('收益日历'),
        actions: const [TerminalAppBarActions()],
      ),
      body: earnings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (list) => _CalendarBody(
          earnings: list,
          year: _year,
          month: _month,
          view: _view,
          calc: _calc,
          onPrev: () => _shift(-1),
          onNext: () => _shift(1),
          onOpenMonth: (m) {
            setState(() {
              _month = m;
              _view = _CalView.month;
            });
          },
          onViewChanged: (v) => setState(() => _view = v),
        ),
      ),
    );
  }

  void _shift(int delta) {
    setState(() {
      if (_view == _CalView.month) {
        _month += delta;
        if (_month < 1) {
          _month = 12;
          _year--;
        } else if (_month > 12) {
          _month = 1;
          _year++;
        }
      } else {
        _year += delta;
      }
    });
  }
}

class _CalendarBody extends StatelessWidget {
  const _CalendarBody({
    required this.earnings,
    required this.year,
    required this.month,
    required this.view,
    required this.calc,
    required this.onPrev,
    required this.onNext,
    required this.onOpenMonth,
    required this.onViewChanged,
  });

  final List<DailyEarning> earnings;
  final int year;
  final int month;
  final _CalView view;
  final DailyEarningsCalculator calc;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<int> onOpenMonth;
  final ValueChanged<_CalView> onViewChanged;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final byDate = {for (final e in earnings) e.date: e};
    final monthSummary = calc.monthOf(earnings, year, month);
    final firstDay = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final leadingBlanks = firstDay.weekday - 1;
    final isYearView = view == _CalView.year;
    final yearSummary = isYearView ? calc.yearOf(earnings, year) : null;
    final prefix = '$year-${month.toString().padLeft(2, '0')}';
    final profits = earnings
        .where((e) => e.date.startsWith(prefix) && e.profit != 0)
        .map((e) => e.profit)
        .toList();
    final minProfit = profits.isEmpty ? 0.0 : profits.reduce(math.min);
    final maxProfit = profits.isEmpty ? 0.0 : profits.reduce(math.max);

    return ResponsiveShell(
      child: ListView(
        padding: const EdgeInsets.all(T.s3),
        children: [
          Center(
            child: SegmentedButton<_CalView>(
              segments: const [
                ButtonSegment(value: _CalView.month, label: Text('月')),
                ButtonSegment(value: _CalView.year, label: Text('年')),
              ],
              selected: {view},
              onSelectionChanged: (s) => onViewChanged(s.first),
            ),
          ),
          const SizedBox(height: T.s3),
          if (isYearView) ...[
            _YearSummary(year: yearSummary!),
            const SizedBox(height: T.s2),
            _navRow('$year年'),
            const SizedBox(height: T.s2),
            _YearGrid(year: year, earnings: earnings, onTapMonth: onOpenMonth),
          ] else ...[
            _MonthSummary(month: monthSummary),
            const SizedBox(height: T.s2),
            _navRow('$year年$month月'),
            const SizedBox(height: T.s2),
            Row(
              children: [
                for (final w in _weekdays)
                  Expanded(child: Center(child: Text(w, style: T.label()))),
              ],
            ),
            const SizedBox(height: T.s1),
            _buildGrid(
              context,
              leadingBlanks: leadingBlanks,
              daysInMonth: daysInMonth,
              byDate: byDate,
              minProfit: minProfit,
              maxProfit: maxProfit,
            ),
          ],
          const SizedBox(height: T.s3),
          Text('盈亏 = 当日净资产 − 前日净资产；负债变化计入当日盈亏', style: T.label()),
        ],
      ),
    );
  }

  Widget _navRow(String label) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
        SizedBox(
          width: 96,
          child: Center(
            child: Text(label, style: T.mono(size: 14, weight: FontWeight.w600)),
          ),
        ),
        IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
      ],
    );
  }

  Widget _buildGrid(
    BuildContext context, {
    required int leadingBlanks,
    required int daysInMonth,
    required Map<String, DailyEarning> byDate,
    required double minProfit,
    required double maxProfit,
  }) {
    final rows = <TableRow>[];
    var day = 1;
    final cellCount = leadingBlanks + daysInMonth;
    final weekCount = (cellCount + 6) ~/ 7;
    for (var w = 0; w < weekCount; w++) {
      final cells = <Widget>[];
      for (var c = 0; c < 7; c++) {
        final index = w * 7 + c;
        if (index < leadingBlanks || day > daysInMonth) {
          cells.add(const SizedBox.shrink());
        } else {
          final date = DateTime(year, month, day);
          final dateStr = date.toIso8601String().substring(0, 10);
          final earning = byDate[dateStr];
          cells.add(
            _DayCell(
              day: day,
              earning: earning,
              date: date,
              minProfit: minProfit,
              maxProfit: maxProfit,
              onTap: earning == null ? null : () => _openDay(context, date),
            ),
          );
          day++;
        }
      }
      rows.add(TableRow(children: cells));
    }
    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: {
        for (var i = 0; i < 7; i++) i: const FlexColumnWidth(),
      },
      children: rows,
    );
  }

  void _openDay(BuildContext context, DateTime date) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => DayDetailSheet(date: date),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.earning,
    required this.date,
    required this.minProfit,
    required this.maxProfit,
    this.onTap,
  });

  final int day;
  final DailyEarning? earning;
  final DateTime date;
  final double minProfit;
  final double maxProfit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isToday = _isToday(date);
    final hasEarning = earning != null && earning!.profit != 0;
    final profit = earning?.profit ?? 0;
    return HeatCell(
      value: profit,
      min: minProfit,
      max: maxProfit,
      height: 44,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$day',
            style: T.mono(
              size: 11,
              weight: isToday ? FontWeight.w700 : FontWeight.w400,
              color: isToday ? T.accent : T.text2,
            ),
          ),
          const SizedBox(height: T.s1),
          Text(
            earning == null
                ? ''
                : hasEarning
                    ? '${profit >= 0 ? '+' : ''}${Formats.amountCompact(profit)}'
                    : '0',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.mono(
              size: 10,
              color: hasEarning ? T.changeColor(profit) : T.text3,
            ),
          ),
        ],
      ),
    );
  }

  static bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }
}

class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.month});

  final MonthlyEarnings month;

  @override
  Widget build(BuildContext context) {
    final rate = month.rate;
    final hasEarning = month.total != 0;
    return TerminalCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('本月收益', style: T.label()),
                const SizedBox(height: T.s1),
                Text(
                  '${month.total >= 0 ? '+' : ''}${Formats.amount(month.total)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.mono(
                    size: 22,
                    weight: FontWeight.w700,
                    color: hasEarning ? T.changeColor(month.total) : T.text3,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('月收益率', style: T.label()),
              const SizedBox(height: T.s1),
              Text(
                rate == null ? '--' : Formats.pct(rate),
                style: T.mono(
                  size: 18,
                  weight: FontWeight.w700,
                  color: rate == null ? T.text3 : T.changeColor(rate),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _YearSummary extends StatelessWidget {
  const _YearSummary({required this.year});

  final YearlyEarnings year;

  @override
  Widget build(BuildContext context) {
    final rate = year.rate;
    final hasEarning = year.total != 0;
    return TerminalCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('本年收益', style: T.label()),
                const SizedBox(height: T.s1),
                Text(
                  '${year.total >= 0 ? '+' : ''}${Formats.amount(year.total)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.mono(
                    size: 22,
                    weight: FontWeight.w700,
                    color: hasEarning ? T.changeColor(year.total) : T.text3,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('年收益率', style: T.label()),
              const SizedBox(height: T.s1),
              Text(
                rate == null ? '--' : Formats.pct(rate),
                style: T.mono(
                  size: 18,
                  weight: FontWeight.w700,
                  color: rate == null ? T.text3 : T.changeColor(rate),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _YearGrid extends StatelessWidget {
  const _YearGrid({
    required this.year,
    required this.earnings,
    required this.onTapMonth,
  });

  final int year;
  final List<DailyEarning> earnings;
  final ValueChanged<int> onTapMonth;

  static const _monthNames = [
    '1月', '2月', '3月', '4月', '5月', '6月',
    '7月', '8月', '9月', '10月', '11月', '12月',
  ];

  @override
  Widget build(BuildContext context) {
    final calc = const DailyEarningsCalculator();
    final byMonth = {
      for (var m = 1; m <= 12; m++) m: calc.monthOf(earnings, year, m),
    };
    final maxAbs = byMonth.values.map((m) => m.total.abs()).reduce(math.max);
    final rows = <TableRow>[];
    for (var r = 0; r < 4; r++) {
      final cells = <Widget>[];
      for (var c = 0; c < 3; c++) {
        final m = r * 3 + c + 1;
        final agg = byMonth[m]!;
        cells.add(
          _MonthTile(
            label: _monthNames[m - 1],
            month: agg,
            maxAbs: maxAbs,
            onTap: agg.days > 0 ? () => onTapMonth(m) : null,
          ),
        );
      }
      rows.add(TableRow(children: cells));
    }
    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: {
        for (var i = 0; i < 3; i++) i: const FlexColumnWidth(),
      },
      children: rows,
    );
  }
}

class _MonthTile extends StatelessWidget {
  const _MonthTile({
    required this.label,
    required this.month,
    required this.maxAbs,
    this.onTap,
  });

  final String label;
  final MonthlyEarnings month;
  final double maxAbs;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasData = month.days > 0;
    final hasEarning = hasData && month.total != 0;
    final frac = maxAbs == 0
        ? 0.0
        : (month.total.abs() / maxAbs).clamp(0.0, 1.0);
    return TerminalCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: T.s2, vertical: T.s2),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: T.label()),
          const SizedBox(height: T.s1),
          Text(
            !hasData
                ? '--'
                : hasEarning
                    ? '${month.total >= 0 ? '+' : ''}${Formats.amountCompact(month.total)}'
                    : '0',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.mono(
              size: 12,
              weight: FontWeight.w600,
              color: hasEarning ? T.changeColor(month.total) : T.text3,
            ),
          ),
          const SizedBox(height: T.s2),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: T.s1,
              backgroundColor: T.surface2,
              valueColor: AlwaysStoppedAnimation(
                hasEarning ? T.changeColor(month.total) : T.text3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
