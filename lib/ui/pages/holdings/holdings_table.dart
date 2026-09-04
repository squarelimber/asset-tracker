import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../../domain/trade_stats.dart';
import '../../components/delta_text.dart';
import '../../components/empty_state.dart';
import '../../components/status_chip.dart';
import '../../tokens.dart';

enum HoldingSection { assets, liabilities }

class HoldingsTable extends ConsumerWidget {
  const HoldingsTable({
    super.key,
    required this.section,
    required this.assets,
    required this.liabilities,
    required this.rates,
    required this.onHoldingTap,
  });

  final HoldingSection section;
  final List<HoldingRow> assets;
  final List<HoldingRow> liabilities;
  final Map<String, double> rates;
  final void Function(HoldingRow) onHoldingTap;

  static const _cols = ['名称', '代码', '数量', '成本', '最新', '盈亏 / 收益率'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = section == HoldingSection.assets ? assets : liabilities;
    if (list.isEmpty) {
      return const EmptyState(message: '暂无数据');
    }
    return CustomScrollView(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _TableHeaderDelegate(),
        ),
        SliverToBoxAdapter(
          child: Column(
            children: [
              for (final h in list) _TableRow(h: h, onHoldingTap: onHoldingTap),
            ],
          ),
        ),
      ],
    );
  }
}

class _TableHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _TableHeaderDelegate();

  @override
  double get maxExtent => 40;
  @override
  double get minExtent => 40;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: T.surface2,
      padding: const EdgeInsets.symmetric(horizontal: T.s3),
      child: Row(
        children: [
          for (final c in HoldingsTable._cols)
            Expanded(
              flex: c == '名称' ? 3 : (c == '盈亏 / 收益率' ? 3 : 2),
              child: Align(
                alignment: c == '名称' || c == '代码'
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: Text(c, style: T.label(size: 11, color: T.text2)),
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TableHeaderDelegate old) => false;
}

class _TableRow extends ConsumerWidget {
  const _TableRow({required this.h, required this.onHoldingTap});

  final HoldingRow h;
  final void Function(HoldingRow) onHoldingTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = AssetType.fromStorage(h.assetType);
    final isLiability = type == AssetType.liability;
    final isAmount = type.isAmountBased;
    final closed = isHoldingClosed(h);
    final marketValue = isAmount ? h.quantity : h.quantity * h.latestPrice;
    final cost = isAmount
        ? (h.costPrice > 0 ? h.costPrice : h.quantity)
        : h.quantity * h.costPrice;
    final profit = marketValue - cost;
    final profitPct = cost == 0 ? 0.0 : profit / cost;
    // Sold-out positions show their realized P&L instead of live quotes.
    final closedTxns = closed && !isLiability
        ? ref.watch(transactionsByHoldingProvider(h.id)).valueOrNull ??
            const <TransactionRow>[]
        : const <TransactionRow>[];
    final realized = closed && !isLiability
        ? (TradeStatsCalculator.realizedProfitByHolding(
            closedTxns,
            {h.id: h.costPrice},
          )[h.id] ??
          0)
        : 0.0;
    final invested = closedTxns
        .where((t) => TransactionType.fromStorage(t.type) == TransactionType.buy)
        .fold(0.0, (a, t) => a + t.amount);
    final realizedPct = closed && !isLiability && invested > 0
        ? realized / invested
        : null;
    final hide = ref.watch(hideAmountsProvider);
    final dash = Text('--', style: T.mono(size: 13, color: T.text3));
    return InkWell(
      onTap: () => onHoldingTap(h),
      child: Container(
        height: 44,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: T.borderSoft, width: 1)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: T.s3),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  Icon(type.icon, size: 14, color: type.color),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      h.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.mono(size: 14, color: closed || h.archived ? T.text3 : T.text1),
                    ),
                  ),
                  if (closed) StatusChip(closedHoldingLabel(h)),
                  if (h.archived) const StatusChip('已归档'),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  h.symbol ?? '--',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.mono(size: 12, color: T.text3),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerRight,
                child: isAmount
                    ? dash
                    : Text(Formats.smartNum(h.quantity),
                        style: T.mono(size: 13, color: T.text1)),
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerRight,
                child: isAmount
                    ? dash
                    : Text(Formats.smartNum(h.costPrice),
                        style: T.mono(size: 13, color: T.text1)),
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerRight,
                child: isAmount || closed
                    ? dash
                    : Text(Formats.smartNum(h.latestPrice),
                        style: T.mono(size: 13, color: T.text1)),
              ),
            ),
            Expanded(
              flex: 3,
              child: Align(
                alignment: Alignment.centerRight,
                child: isLiability
                    ? Text(
                        hide ? '****' : Formats.money(marketValue, h.currency),
                        style: T.mono(size: 13, color: T.down),
                      )
                    : closed && isAmount
                        ? Text('已结清', style: T.mono(size: 12, color: T.text3))
                        : closed
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  DeltaText(
                                    value: realizedPct ?? 0,
                                    text: hide
                                        ? '****'
                                        : '${realized >= 0 ? '+' : ''}${Formats.money(realized, h.currency)}',
                                  ),
                                  if (realizedPct != null) ...[
                                    const SizedBox(width: 6),
                                    Text(
                                      '(${Formats.pct(realizedPct)})',
                                      style: T.mono(size: 12, color: T.changeColor(realized)),
                                    ),
                                  ],
                                  const SizedBox(width: 8),
                                  Text('已实现', style: T.mono(size: 10, color: T.text3)),
                                ],
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  DeltaText(
                                    value: profitPct,
                                    text: hide
                                        ? '****'
                                        : '${profit >= 0 ? '+' : ''}${Formats.money(profit, h.currency)}',
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '(${Formats.pct(profitPct)})',
                                    style: T.mono(size: 12, color: T.changeColor(profit)),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    hide ? '****' : Formats.money(marketValue, h.currency),
                                    style: T.mono(size: 11, color: T.text3),
                                  ),
                                ],
                              ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
