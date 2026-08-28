import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../ui/components/app_bar_actions.dart';
import '../../ui/tokens.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../domain/daily_earnings.dart';
import '../portfolio/day_detail_sheet.dart';

/// Daily earnings by date, computed from snapshots (cost-basis view).
/// Watches the snapshot stream directly so backfill rebuilds and today's
/// snapshot refresh immediately update the calendar.
final _earningsProvider = FutureProvider<List<DailyEarning>>((ref) async {
  final snapshots = ref.watch(snapshotsProvider).value ?? const [];
  return const DailyEarningsCalculator().compute(snapshots);
});

/// Alipay-style earnings calendar: month grid of daily profits with a
/// monthly total, tapping a day opens the holding detail sheet.
class EarningsCalendarPage extends ConsumerStatefulWidget {
  const EarningsCalendarPage({super.key});

  @override
  ConsumerState<EarningsCalendarPage> createState() =>
      _EarningsCalendarPageState();
}

enum _CalView { month, year }

class _EarningsCalendarPageState extends ConsumerState<EarningsCalendarPage> {
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

  void _shiftMonth(int delta) {
    setState(() {
      final d = DateTime(_year, _month + delta, 1);
      _year = d.year;
      _month = d.month;
    });
  }

  void _shiftYear(int delta) {
    setState(() => _year += delta);
  }

  void _openMonth(int month) {
    setState(() {
      _month = month;
      _view = _CalView.month;
    });
  }

  void _setView(_CalView view) {
    setState(() => _view = view);
  }

  @override
  Widget build(BuildContext context) {
    // Trigger the shared history sync so the calendar and the dashboard
    // show the same snapshots (backfill + today's refresh).
    ref.watch(historySyncProvider);
    final earnings = ref.watch(_earningsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('收益日历'),
        actions: [const TerminalAppBarActions()],
      ),
      body: earnings.when(
        data: (list) => _CalendarBody(
          earnings: list,
          year: _year,
          month: _month,
          view: _view,
          onShiftMonth: _shiftMonth,
          onShiftYear: _shiftYear,
          onOpenMonth: _openMonth,
          onViewChanged: _setView,
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }
}

class _CalendarBody extends StatelessWidget {
  const _CalendarBody({
    required this.earnings,
    required this.year,
    required this.month,
    required this.view,
    required this.onShiftMonth,
    required this.onShiftYear,
    required this.onOpenMonth,
    required this.onViewChanged,
  });

  final List<DailyEarning> earnings;
  final int year;
  final int month;
  final _CalView view;
  final ValueChanged<int> onShiftMonth;
  final ValueChanged<int> onShiftYear;
  final ValueChanged<int> onOpenMonth;
  final ValueChanged<_CalView> onViewChanged;

  @override
  Widget build(BuildContext context) {
    final calc = const DailyEarningsCalculator();
    final byDate = {for (final e in earnings) e.date: e};
    final month = calc.monthOf(earnings, year, this.month);

    final firstDay = DateTime(year, this.month, 1);
    final daysInMonth = DateTime(year, this.month + 1, 0).day;
    // Monday-first offset (1 = Monday .. 7 = Sunday).
    final leadingBlanks = (firstDay.weekday - 1);

    final isYearView = view == _CalView.year;
    final yearSummary = isYearView ? calc.yearOf(earnings, year) : null;

    return ResponsiveShell(
      child: ListView(
        children: [
          Center(
            child: SegmentedButton<_CalView>(
              segments: const [
                ButtonSegment(value: _CalView.month, label: Text('月')),
                ButtonSegment(value: _CalView.year, label: Text('年')),
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
          if (isYearView) ...[
            _YearSummary(year: yearSummary!),
            const SizedBox(height: 16),
            Row(
              children: [
                IconButton(
                  tooltip: '上一年',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => onShiftYear(-1),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '$year年',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下一年',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => onShiftYear(1),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _YearGrid(year: year, earnings: earnings, onTapMonth: onOpenMonth),
          ] else ...[
            _MonthSummary(month: month),
            const SizedBox(height: 16),
            Row(
              children: [
                IconButton(
                  tooltip: '上一月',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => onShiftMonth(-1),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '$year年${this.month}月',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下一月',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => onShiftMonth(1),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final label in ['一', '二', '三', '四', '五', '六', '日'])
                  Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            _buildGrid(context, leadingBlanks, daysInMonth, byDate),
          ],
          const SizedBox(height: 12),
          Text(
            '收益为成本法口径：已剔除转入转出、还款借款等资金进出影响；点击日期查看当天持仓明细。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(
    BuildContext context,
    int leadingBlanks,
    int daysInMonth,
    Map<String, DailyEarning> byDate,
  ) {
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
          final dateStr =
              '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
          final earning = byDate[dateStr];
          cells.add(_DayCell(
            day: day,
            earning: earning,
            date: DateTime(year, month, day),
          ));
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

class _YearSummary extends StatelessWidget {
  const _YearSummary({required this.year});

  final YearlyEarnings year;

  @override
  Widget build(BuildContext context) {
    final rate = year.rate;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本年收益', style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text(
                    '${year.total >= 0 ? '+' : ''}¥${Formats.amount(year.total)}',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: context.changeColor(year.total),
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('年收益率', style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 4),
                Text(
                  rate == null ? '--' : Formats.pct(rate),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: rate == null
                            ? Theme.of(context).colorScheme.outline
                            : context.changeColor(rate),
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
          ],
        ),
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
    final rows = <TableRow>[];
    for (var r = 0; r < 4; r++) {
      final cells = <Widget>[];
      for (var c = 0; c < 3; c++) {
        final m = r * 3 + c + 1;
        cells.add(_MonthCell(
          label: _monthNames[m - 1],
          month: byMonth[m]!,
          onTap: byMonth[m]!.days > 0 ? () => onTapMonth(m) : null,
        ));
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

class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.label,
    required this.month,
    required this.onTap,
  });

  final String label;
  final MonthlyEarnings month;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasData = month.days > 0;
    final hasEarning = hasData && month.total != 0;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              !hasData
                  ? '--'
                  : hasEarning
                      ? '${month.total >= 0 ? '+' : ''}${Formats.amountCompact(month.total)}'
                      : '0',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: hasEarning
                    ? context.changeColor(month.total)
                    : Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.month});

  final MonthlyEarnings month;

  @override
  Widget build(BuildContext context) {
    final rate = month.rate;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本月收益', style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text(
                    '${month.total >= 0 ? '+' : ''}¥${Formats.amount(month.total)}',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: context.changeColor(month.total),
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('月收益率', style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 4),
                Text(
                  rate == null ? '--' : Formats.pct(rate),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: rate == null
                            ? Theme.of(context).colorScheme.outline
                            : context.changeColor(rate),
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, required this.earning, required this.date});

  final int day;
  final DailyEarning? earning;
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final hasEarning = earning != null && earning!.profit != 0;
    final isToday = _isToday(date);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: earning == null
          ? null
          : () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                isScrollControlled: true,
                builder: (context) => DayDetailSheet(date: date),
              ),
      child: Container(
        margin: const EdgeInsets.all(3),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: isToday
              ? T.up.withValues(alpha: 0.10)
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$day',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: isToday ? FontWeight.w700 : null,
                  ),
            ),
            const SizedBox(height: 2),
            Text(
              earning == null
                  ? ' '
                  : hasEarning
                      ? '${earning!.profit >= 0 ? '+' : ''}${Formats.amountCompact(earning!.profit)}'
                      : '0',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: hasEarning
                    ? context.changeColor(earning!.profit)
                    : Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }
}
