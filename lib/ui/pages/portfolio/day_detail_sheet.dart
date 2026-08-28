import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../domain/holding_details.dart';
import '../../tokens.dart';

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
              return const SizedBox(
                height: 120,
                child: Center(child: Text('无数据', style: TextStyle(color: T.text3))),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${Formats.date(date)} 持仓明细',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: T.text1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '当日总资产（折算人民币）${hideAmounts ? Formats.masked() : Formats.money(d.totalValue)}',
                  style: T.mono(size: 12, color: T.text2),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final item in d.items)
                        _DetailRow(item: item, hideAmounts: hideAmounts),
                      const Divider(color: T.border, height: 16),
                      Text(
                        '点击走势图任意日期可查看当天明细',
                        style: T.mono(size: 12, color: T.text3),
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
              child: Text('加载失败: $e', style: const TextStyle(color: T.text3)),
            ),
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
    final change = item.dayChange;
    final changeCny = change == null ? null : change * item.cnyRate;
    final pct = item.dayChangePct;
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
                  style: const TextStyle(fontSize: 14, color: T.text1),
                ),
                Text(
                  type == AssetType.liability
                      ? '负债 · 市值 ${money(item.marketValueCny)}'
                      : '单价 ${Formats.smartNum(item.price)} · 市值 ${money(item.marketValueCny)}',
                  style: T.mono(size: 12, color: T.text2),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            changeCny == null
                ? '--'
                : '${changeCny >= 0 ? '+' : ''}${money(changeCny)}'
                    '${pct == null ? '' : ' (${Formats.pct(pct)})'}',
            textAlign: TextAlign.end,
            style: T.mono(
              size: 14,
              weight: FontWeight.w600,
              color: changeCny == null ? T.text3 : T.changeColor(changeCny),
            ),
          ),
        ],
      ),
    );
  }
}
