import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
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

class _EarningsCalendarPageState extends ConsumerState<EarningsCalendarPage> {
  late int _year;
  late int _month;

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

  @override
  Widget build(BuildContext context) {
    // Trigger the shared history sync so the calendar and the dashboard
    // show the same snapshots (backfill + today's refresh).
    ref.watch(historySyncProvider);
    final earnings = ref.watch(_earningsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('收益日历')),
      body: earnings.when(
        data: (list) => _CalendarBody(
          earnings: list,
          year: _year,
          month: _month,
          onShiftMonth: _shiftMonth,
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
    required this.onShiftMonth,
  });

  final List<DailyEarning> earnings;
  final int year;
  final int month;
  final ValueChanged<int> onShiftMonth;

  @override
  Widget build(BuildContext context) {
    final byDate = {for (final e in earnings) e.date: e};
    final month = const DailyEarningsCalculator().monthOf(earnings, year, this.month);

    final firstDay = DateTime(year, this.month, 1);
    final daysInMonth = DateTime(year, this.month + 1, 0).day;
    // Monday-first offset (1 = Monday .. 7 = Sunday).
    final leadingBlanks = (firstDay.weekday - 1);

    return ResponsiveShell(
      child: ListView(
        children: [
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
          const SizedBox(height: 12),
          Text(
            '收益为成本法口径：已剔除转入转出等资金进出影响；点击日期查看当天持仓明细。',
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
              ? AppColors.up.withValues(alpha: 0.10)
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
