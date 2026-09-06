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
import 'holdings_page.dart';

enum HoldingSection { assets, liabilities }

class HoldingsTable extends ConsumerWidget {
  const HoldingsTable({
    super.key,
    required this.section,
    required this.assets,
    required this.liabilities,
    required this.rates,
    required this.onHoldingTap,
    this.sort = HoldingSort.defaultOrder,
    this.onSortChanged,
    this.onHoldingMenu,
  });

  final HoldingSection section;
  final List<HoldingRow> assets;
  final List<HoldingRow> liabilities;
  final Map<String, double> rates;
  final void Function(HoldingRow) onHoldingTap;

  /// Current sort mode (drives the header arrows).
  final HoldingSort sort;

  /// Called when a header cell is clicked.
  final ValueChanged<HoldingSort>? onSortChanged;

  /// Row context menu (right-click / long-press). [at] is the global
  /// anchor position, or null to anchor below the row.
  final void Function(HoldingRow, Offset?)? onHoldingMenu;

  /// Header columns: label, width flex, alignment and the (default, other)
  /// sort pair toggled by clicking the header.
  static const _cols = [
    (label: '名称', flex: 3, align: Alignment.centerLeft, pair: (HoldingSort.nameAsc, HoldingSort.nameDesc)),
    (label: '代码', flex: 2, align: Alignment.centerLeft, pair: (HoldingSort.symbolAsc, HoldingSort.symbolDesc)),
    (label: '数量', flex: 2, align: Alignment.centerRight, pair: (HoldingSort.quantityDesc, HoldingSort.quantityAsc)),
    (label: '成本', flex: 2, align: Alignment.centerRight, pair: (HoldingSort.costDesc, HoldingSort.costAsc)),
    (label: '最新', flex: 2, align: Alignment.centerRight, pair: (HoldingSort.priceDesc, HoldingSort.priceAsc)),
    (label: '盈亏 / 收益率', flex: 3, align: Alignment.centerRight, pair: (HoldingSort.profitDesc, HoldingSort.profitAsc)),
  ];

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
          delegate: _TableHeaderDelegate(sort: sort, onSortChanged: onSortChanged),
        ),
        SliverToBoxAdapter(
          child: Column(
            children: [
              for (final h in list)
                _TableRow(
                  h: h,
                  onHoldingTap: onHoldingTap,
                  onHoldingMenu: onHoldingMenu,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TableHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _TableHeaderDelegate({required this.sort, required this.onSortChanged});

  final HoldingSort sort;
  final ValueChanged<HoldingSort>? onSortChanged;

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
              flex: c.flex,
              child: _HeaderCell(
                label: c.label,
                align: c.align,
                active: sort == c.pair.$1 || sort == c.pair.$2,
                ascending: sort == c.pair.$1,
                onTap: onSortChanged == null
                    ? null
                    : () => onSortChanged!(
                        sort == c.pair.$1 ? c.pair.$2 : c.pair.$1),
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TableHeaderDelegate old) => old.sort != sort;
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({
    required this.label,
    required this.align,
    required this.active,
    required this.ascending,
    required this.onTap,
  });

  final String label;
  final Alignment align;
  final bool active;
  final bool ascending;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isLeft = align == Alignment.centerLeft;
    final arrow = Icon(
      ascending ? Icons.arrow_drop_up : Icons.arrow_drop_down,
      size: 16,
      color: active ? T.accent : T.text3,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Align(
          alignment: align,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isLeft && active) arrow,
              Text(label, style: T.label(size: 11, color: active ? T.text1 : T.text2)),
              if (isLeft && active) arrow,
            ],
          ),
        ),
      ),
    );
  }
}

class _TableRow extends ConsumerWidget {
  const _TableRow({
    required this.h,
    required this.onHoldingTap,
    this.onHoldingMenu,
  });

  final HoldingRow h;
  final void Function(HoldingRow) onHoldingTap;
  final void Function(HoldingRow, Offset?)? onHoldingMenu;

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
    final row = InkWell(
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
    if (onHoldingMenu == null) return row;
    // Right-click (desktop) or long-press opens the row context menu.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => onHoldingMenu!(h, d.globalPosition),
      onLongPress: () => onHoldingMenu!(h, null),
      child: row,
    );
  }
}
