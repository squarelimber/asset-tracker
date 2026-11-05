import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/formats.dart';
import '../tokens.dart';
import 'terminal_card.dart';

/// Shared by calendar and trend drill-down. Its header and rows describe the
/// same pair of recorded snapshots, not two independent valuation requests.
class DayEarningsPanel extends ConsumerWidget {
  const DayEarningsPanel({super.key, required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(
      earningsBreakdownProvider(DateUtils.dateOnly(date)),
    );
    final hidden = ref.watch(hideAmountsProvider);
    String money(double value) =>
        hidden ? Formats.masked() : Formats.money(value);
    String signed(double value) => hidden
        ? Formats.masked()
        : '${value >= 0 ? '+' : ''}${Formats.money(value)}';
    return TerminalCard(
      margin: EdgeInsets.zero,
      child: detail.when(
        loading: () => const SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, stack) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('收益明细加载失败', style: TextStyle(color: T.text2)),
            TextButton(
              onPressed: () => ref.invalidate(snapshotsProvider),
              child: const Text('重试'),
            ),
          ],
        ),
        data: (data) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${Formats.date(date)} 当日收益明细',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              data.profit == null
                  ? '该日尚无快照，暂不能计算当日收益'
                  : '日历收益 ${signed(data.profit!)}',
              style: T.mono(
                size: 13,
                color: data.profit == null
                    ? T.text2
                    : T.changeColor(data.profit!),
              ),
            ),
            const SizedBox(height: 8),
            if (!data.verified && data.profit != null)
              Text(
                kIsWeb
                    ? '旧快照缺少可核对的持仓明细。请在手机或桌面端重建历史快照后同步。'
                    : '旧快照缺少可核对的持仓明细。请在设置中重建历史快照后重试。',
                style: const TextStyle(
                  fontSize: 12,
                  color: T.warning,
                  height: 1.6,
                ),
              ),
            if (data.verified) ...[
              Text(
                data.baselineDate == null
                    ? '首个快照日无前日基准，收益记为 0'
                    : '对比基准 ${data.baselineDate}；明细合计 ${signed(data.detailTotal)}',
                style: const TextStyle(
                  fontSize: 11,
                  color: T.text2,
                  height: 1.6,
                ),
              ),
              const Divider(height: 24),
              for (final row in data.rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Icon(row.type.icon, size: 16, color: row.type.color),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              row.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            Text(
                              '市值 ${money(row.value)}',
                              style: T.mono(size: 11, color: T.text3),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        signed(row.profit),
                        style: T.mono(
                          size: 13,
                          color: T.changeColor(row.profit),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                '当日收益 = 本次快照的（资产 − 成本）减去上一快照的（资产 − 成本）；负债不计入投资收益。合计按原始精度计算，分项四舍五入可能产生分币尾差。',
                style: TextStyle(fontSize: 11, color: T.text3, height: 1.6),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
