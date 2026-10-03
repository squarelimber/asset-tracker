import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../domain/daily_earnings.dart';
import '../../../services/history_backfill_service.dart';
import '../../components/app_bar_actions.dart';
import '../../components/error_state.dart';
import '../../components/heat_cell.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

final earningsProvider = FutureProvider<List<DailyEarning>>((ref) async {
  final snapshots = ref.watch(snapshotsProvider).value ?? const [];
  return const DailyEarningsCalculator().compute(snapshots);
});

class EarningsCalendarPage extends ConsumerStatefulWidget {
  const EarningsCalendarPage({super.key});

  @override
  ConsumerState<EarningsCalendarPage> createState() =>
      _EarningsCalendarPageState();
}

enum _CalView { month, year }

class _EarningsCalendarPageState extends ConsumerState<EarningsCalendarPage> {
  final _calc = const DailyEarningsCalculator();
  late int _year;
  late int _month;
  _CalView _view = _CalView.month;
  DateTime? _selectedDate;

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
        error: (e, _) => ErrorState(
          message: '收益日历加载失败，请重试',
          onRetry: () => ref.invalidate(earningsProvider),
        ),
        data: (list) => _CalendarBody(
          earnings: list,
          year: _year,
          month: _month,
          view: _view,
          calc: _calc,
          selectedDate: _selectedDate,
          onDayTap: (d) {
            setState(() {
              if (_selectedDate != null &&
                  _selectedDate!.year == d.year &&
                  _selectedDate!.month == d.month &&
                  _selectedDate!.day == d.day) {
                _selectedDate = null; // toggle off
              } else {
                _selectedDate = d;
              }
            });
          },
          onRefresh: () => ref.invalidate(earningsProvider),
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
    required this.onRefresh,
    required this.onPrev,
    required this.onNext,
    required this.onOpenMonth,
    required this.onViewChanged,
    this.selectedDate,
    this.onDayTap,
  });

  final List<DailyEarning> earnings;
  final int year;
  final int month;
  final _CalView view;
  final DailyEarningsCalculator calc;
  final VoidCallback onRefresh;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<int> onOpenMonth;
  final ValueChanged<_CalView> onViewChanged;

  /// Selected day (products are shown inline below the calendar).
  final DateTime? selectedDate;
  final ValueChanged<DateTime>? onDayTap;

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
      child: RefreshIndicator(
        onRefresh: () async => onRefresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
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
              _YearGrid(
                year: year,
                earnings: earnings,
                onTapMonth: onOpenMonth,
              ),
            ] else ...[
              _MonthSummary(month: monthSummary),
              const SizedBox(height: T.s2),
              _navRow('$year年$month月'),
              const SizedBox(height: T.s2),
              Row(
                children: [
                  for (final w in _weekdays)
                    Expanded(
                      child: Center(child: Text(w, style: T.label())),
                    ),
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
              if (selectedDate != null) ...[
                const SizedBox(height: T.s3),
                _DayEarningsPanel(date: selectedDate!),
              ],
            ],
            const SizedBox(height: T.s3),
            Text(
              '盈亏 = 当日净资产 − 前日净资产；负债变动不计入当日盈亏；点击日期查看当日各产品收益',
              style: T.label(),
            ),
          ],
        ),
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
            child: Text(
              label,
              style: T.mono(size: 14, weight: FontWeight.w600),
            ),
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
              selected:
                  selectedDate != null &&
                  selectedDate!.year == date.year &&
                  selectedDate!.month == date.month &&
                  selectedDate!.day == date.day,
              onTap: earning == null ? null : () => onDayTap?.call(date),
            ),
          );
          day++;
        }
      }
      rows.add(TableRow(children: cells));
    }
    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: {for (var i = 0; i < 7; i++) i: const FlexColumnWidth()},
      children: rows,
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
    this.selected = false,
    this.onTap,
  });

  final int day;
  final DailyEarning? earning;
  final DateTime date;
  final double minProfit;
  final double maxProfit;
  final bool selected;
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
      borderColor: selected ? T.accent : null,
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
    '1月',
    '2月',
    '3月',
    '4月',
    '5月',
    '6月',
    '7月',
    '8月',
    '9月',
    '10月',
    '11月',
    '12月',
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
      columnWidths: {for (var i = 0; i < 3; i++) i: const FlexColumnWidth()},
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
    final tile = TerminalCard(
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
    return tile;
  }
}

/// Inline panel under the calendar showing each product's **day** earnings
/// on the selected date (same cost-basis convention as the calendar:
/// Δ(value − cost), CNY-converted, one row per product). Products that lost
/// money that day render negative and red, so the source of a negative
/// calendar day is directly visible.
class _DayEarningsPanel extends ConsumerWidget {
  const _DayEarningsPanel({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hideAmounts = ref.watch(hideAmountsProvider);
    // 当天与前一天的逐持仓 (value, cost) —— 与快照回放同一口径，因此
    // 合计严格等于收益日历格子数字（不再用 productEarnings 的独立路径，
    // 两条路径曾彼此漂移）。
    final todayAsync = ref.watch(dayHoldingsBreakdownProvider(date));
    final prevDay = DateTime(date.year, date.month, date.day - 1);
    final prevAsync = ref.watch(dayHoldingsBreakdownProvider(prevDay));

    String money(double v) => hideAmounts ? Formats.masked() : Formats.money(v);

    final loading = todayAsync.isLoading || prevAsync.isLoading;
    final error = todayAsync.hasError || prevAsync.hasError
        ? (todayAsync.error ?? prevAsync.error)
        : null;
    if (loading) {
      return TerminalCard(
        padding: const EdgeInsets.fromLTRB(T.s3, T.s3, T.s3, T.s2),
        child: const SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (error != null) {
      return TerminalCard(
        padding: const EdgeInsets.fromLTRB(T.s3, T.s3, T.s3, T.s2),
        child: Row(
          children: [
            const Text('明细加载失败', style: TextStyle(color: T.text2)),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                ref.invalidate(dayHoldingsBreakdownProvider(date));
                ref.invalidate(dayHoldingsBreakdownProvider(prevDay));
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    final today = todayAsync.value ?? const <DayHoldingValue>[];
    final prev = prevAsync.value ?? const <DayHoldingValue>[];
    // 按持仓 id 合并：当日 vs 前日的 (value − cost)。
    final prevByHolding = {for (final p in prev) p.holdingId: p};
    final rows = <_DayRow>[];
    for (final t in today) {
      if (t.liability) continue; // 负债不进入产品收益行
      final p = prevByHolding[t.holdingId];
      final profit = p == null ? 0.0 : (t.value - t.cost) - (p.value - p.cost);
      rows.add(
        _DayRow(name: t.name, type: t.type, value: t.value, profit: profit),
      );
    }
    rows.sort((a, b) => b.profit.compareTo(a.profit));
    final totalProfit = rows.fold(0.0, (s, r) => s + r.profit);
    if (rows.isEmpty) {
      return TerminalCard(
        padding: const EdgeInsets.fromLTRB(T.s3, T.s3, T.s3, T.s2),
        child: const SizedBox(
          height: 60,
          child: Center(
            child: Text('当日无产品数据', style: TextStyle(color: T.text3)),
          ),
        ),
      );
    }
    return TerminalCard(
      padding: const EdgeInsets.fromLTRB(T.s3, T.s3, T.s3, T.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${Formats.date(date)} 产品收益（当日）',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: T.text1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '合计 ${totalProfit >= 0 ? '+' : ''}${money(totalProfit)}'
            ' · 与本日历当日一致',
            style: T.mono(size: 11, color: T.text3),
          ),
          const SizedBox(height: T.s2),
          for (final r in rows) _DayRowTile(row: r, money: money),
        ],
      ),
    );
  }
}

class _DayRow {
  const _DayRow({
    required this.name,
    required this.type,
    required this.value,
    required this.profit,
  });

  final String name;
  final AssetType type;
  final double value;
  final double profit;
}

class _DayRowTile extends StatelessWidget {
  const _DayRowTile({required this.row, required this.money});

  final _DayRow row;
  final String Function(double) money;

  @override
  Widget build(BuildContext context) {
    final hasProfit = row.profit != 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(row.type.icon, size: 16, color: row.type.color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              row.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: T.text1),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            hasProfit
                ? '${row.profit >= 0 ? '+' : ''}${money(row.profit)}'
                : '--',
            style: T.mono(
              size: 13,
              weight: FontWeight.w600,
              color: hasProfit ? T.changeColor(row.profit) : T.text3,
            ),
          ),
        ],
      ),
    );
  }
}
