import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../domain/holding_details.dart';

/// Per-day holding breakdown panel, shared by the net worth trend chart
/// and the earnings calendar.
class DayDetailSheet extends ConsumerWidget {
  const DayDetailSheet({super.key, required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(dayDetailProvider(date));
    final hideAmounts = ref.watch(hideAmountsProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: detail.when(
          data: (d) {
            if (d == null) {
              return const SizedBox(height: 120, child: Center(child: Text('无数据')));
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${Formats.date(date)} 持仓明细',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '当日总资产（折算人民币）${hideAmounts ? Formats.masked() : Formats.money(d.totalValue)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final item in d.items)
                        _DetailRow(item: item, hideAmounts: hideAmounts),
                      const Divider(height: 16),
                      Text(
                        '点击走势图任意日期可查看当天明细',
                        style: Theme.of(context).textTheme.bodySmall,
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
            child: Center(child: Text('加载失败: $e')),
          ),
        ),
      ),
    );
  }
}

final dayDetailProvider = FutureProvider.autoDispose.family<DayDetail?, DateTime>(
  (ref, day) async {
    final rates = await ref.watch(cnyRatesProvider.future);
    return ref.watch(holdingDetailServiceProvider).compute(day, cnyRates: rates);
  },
);

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.item, required this.hideAmounts});

  final HoldingDayDetail item;
  final bool hideAmounts;

  @override
  Widget build(BuildContext context) {
    final type = AssetType.fromStorage(item.holding.assetType);
    String money(double v) => hideAmounts ? Formats.masked() : Formats.money(v);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(type.icon, size: 18, color: type.color),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.holding.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Text(
                  type == AssetType.liability
                      ? '负债'
                      : '单价 ${Formats.smartNum(item.price)} · 成本 ${money(item.costCny)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              money(item.marketValueCny),
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${(item.ratio * 100).toStringAsFixed(1)}%',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
