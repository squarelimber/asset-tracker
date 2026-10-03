import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../tokens.dart';

/// Per-day holding breakdown panel, shared by the net worth trend chart
/// and the earnings calendar.
///
/// The daily figure uses the SAME cost-basis convention as the earnings
/// calendar and the product earnings calendar: day change = Δ(value − cost)
/// from the per-day product series. A holding whose value fell on the day
/// (including FX/gold moves on market holidays) therefore shows a negative
/// number here — the product that produced the calendar's negative day is
/// directly visible. This replaced the old price-delta view, whose
/// forward-filled historical prices never agreed with the snapshot-based
/// calendar total.
class DayDetailSheet extends ConsumerWidget {
  const DayDetailSheet({super.key, required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final year = date.year;
    // The product earnings provider already merges holdings by name and
    // converts to CNY. It writes to the same cache the calendar uses, so
    // this stays consistent with the day's calendar number.
    final productsAsync = ref.watch(productEarningsProvider(year));
    final hideAmounts = ref.watch(hideAmountsProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: productsAsync.when(
          data: (products) {
            final dateKey =
                '${date.year.toString().padLeft(4, '0')}-'
                '${date.month.toString().padLeft(2, '0')}-'
                '${date.day.toString().padLeft(2, '0')}';
            // (product, value, cost) for the tapped day, computed per
            // product; rows missing that date are omitted.
            final rows = <_DayRow>[];
            var totalValue = 0.0;
            for (final p in products) {
              // p.daily is ascending; find an entry on/just before the day.
              _DailyPoint? point;
              for (final d in p.daily) {
                if (d.date.compareTo(dateKey) <= 0) {
                  point = _DailyPoint(d.date, d.value, d.cost);
                } else {
                  break;
                }
              }
              if (point == null) continue;
              final profit = point.value - point.cost;
              totalValue += point.value;
              rows.add(
                _DayRow(
                  name: p.name,
                  type: p.type,
                  value: point.value,
                  profit: profit,
                ),
              );
            }
            if (rows.isEmpty) {
              return const SizedBox(
                height: 120,
                child: Center(
                  child: Text('当日无产品数据', style: TextStyle(color: T.text3)),
                ),
              );
            }
            // Sort by profit descending; negative (loss) products sink to
            // the bottom but stay visible.
            rows.sort((a, b) => b.profit.compareTo(a.profit));
            String money(double v) =>
                hideAmounts ? Formats.masked() : Formats.money(v);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${Formats.date(date)} 产品收益明细',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: T.text1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '当日资产合计（折算人民币）${hideAmounts ? Formats.masked() : Formats.money(totalValue)} · 收益约 ${money(rows.fold(0.0, (s, r) => s + r.profit))}',
                  style: T.mono(size: 12, color: T.text2),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final r in rows)
                        _DetailRow(row: r, hideAmounts: hideAmounts),
                      const Divider(color: T.border, height: 16),
                      Text(
                        '同一口径与收益日历一致：当日收益 = 资产变动 − 成本变动，'
                        '负数为当日亏损产品（含节假日汇率/黄金波动）',
                        style: T.mono(size: 11, color: T.text3),
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
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('加载失败', style: TextStyle(color: T.text2)),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () =>
                        ref.invalidate(productEarningsProvider(year)),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DailyPoint {
  const _DailyPoint(this.date, this.value, this.cost);

  final String date;
  final double value;
  final double cost;
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.row, required this.hideAmounts});

  final _DayRow row;
  final bool hideAmounts;

  @override
  Widget build(BuildContext context) {
    String money(double v) => hideAmounts ? Formats.masked() : Formats.money(v);
    final hasProfit = row.profit != 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(row.type.icon, size: 18, color: row.type.color),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, color: T.text1),
                ),
                Text(
                  '市值 ${money(row.value)}',
                  style: T.mono(size: 12, color: T.text2),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            hasProfit
                ? '${row.profit >= 0 ? '+' : ''}${money(row.profit)}'
                : '--',
            textAlign: TextAlign.end,
            style: T.mono(
              size: 14,
              weight: FontWeight.w600,
              color: hasProfit ? T.changeColor(row.profit) : T.text3,
            ),
          ),
        ],
      ),
    );
  }
}
