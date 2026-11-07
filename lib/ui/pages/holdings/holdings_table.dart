import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../../domain/holding_cost.dart';
import '../../../domain/trade_stats.dart';
import '../../components/delta_text.dart';
import '../../components/status_chip.dart';
import '../../tokens.dart';
import 'holding_menu.dart';
import 'holdings_page.dart';

enum HoldingSection { assets, liabilities }

/// Desktop holdings grid.
///
/// Every figure in a row is in the holding's **own currency** — only the
/// section totals on the page around it (see `assetTotalOf` /
/// `liabilityTotalOf`) are converted to CNY. That is deliberate: a row
/// should read the way the broker reports it. It does mean a row and the
/// total above it are not directly comparable for a foreign holding, so the
/// CNY conversion is not accepted here as a parameter — passing rates in
/// without using them would suggest the rows were already converted.
class HoldingsTable extends ConsumerWidget {
  const HoldingsTable({
    super.key,
    required this.section,
    required this.rows,
    required this.onHoldingTap,
    this.sort = HoldingSort.defaultOrder,
    this.onSortChanged,
    this.onHoldingMenu,
  });

  final HoldingSection section;
  final List<HoldingRow> rows;
  final void Function(HoldingRow) onHoldingTap;

  /// Current sort mode (drives the header arrows).
  final HoldingSort sort;

  /// Called when a header cell is clicked.
  final ValueChanged<HoldingSort>? onSortChanged;

  /// Row actions, anchored at the pointer or overflow button.
  final void Function(HoldingRow, Offset)? onHoldingMenu;

  /// Header columns: label, width flex, alignment and the (default, other)
  /// sort pair toggled by clicking the header.
  static const _cols = [
    (
      label: '名称',
      flex: 3,
      align: Alignment.centerLeft,
      pair: (HoldingSort.nameAsc, HoldingSort.nameDesc),
    ),
    (
      label: '代码',
      flex: 2,
      align: Alignment.centerLeft,
      pair: (HoldingSort.symbolAsc, HoldingSort.symbolDesc),
    ),
    (
      label: '数量',
      flex: 2,
      align: Alignment.centerRight,
      pair: (HoldingSort.quantityDesc, HoldingSort.quantityAsc),
    ),
    (
      label: '成本',
      flex: 2,
      align: Alignment.centerRight,
      pair: (HoldingSort.costDesc, HoldingSort.costAsc),
    ),
    (
      label: '最新价',
      flex: 2,
      align: Alignment.centerRight,
      pair: (HoldingSort.priceDesc, HoldingSort.priceAsc),
    ),
    (
      label: '市值',
      flex: 3,
      align: Alignment.centerRight,
      pair: (HoldingSort.amountDesc, HoldingSort.amountAsc),
    ),
    (
      label: '盈亏 / 收益率',
      flex: 4,
      align: Alignment.centerRight,
      pair: (HoldingSort.profitDesc, HoldingSort.profitAsc),
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CustomScrollView(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _TableHeaderDelegate(
            liabilities: section == HoldingSection.liabilities,
            showActions: onHoldingMenu != null,
            sort: sort,
            onSortChanged: onSortChanged,
          ),
        ),
        SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, index) => _TableRow(
            h: rows[index],
            alternate: index.isOdd,
            onHoldingTap: onHoldingTap,
            onHoldingMenu: onHoldingMenu,
          ),
        ),
      ],
    );
  }
}

class _TableHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _TableHeaderDelegate({
    required this.liabilities,
    required this.showActions,
    required this.sort,
    required this.onSortChanged,
  });

  final bool liabilities;
  final bool showActions;
  final HoldingSort sort;
  final ValueChanged<HoldingSort>? onSortChanged;

  @override
  double get maxExtent => 40;
  @override
  double get minExtent => 40;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final columns = liabilities
        ? [HoldingsTable._cols.first, HoldingsTable._cols[5]]
        : HoldingsTable._cols;
    return Container(
      color: T.surface2,
      padding: const EdgeInsets.symmetric(horizontal: T.s3),
      child: Row(
        children: [
          for (final c in columns)
            Expanded(
              flex: c.flex,
              child: _HeaderCell(
                label: liabilities && c.label == '市值' ? '余额' : c.label,
                align: c.align,
                active: sort == c.pair.$1 || sort == c.pair.$2,
                ascending: sort.name.endsWith('Asc'),
                onTap: onSortChanged == null
                    ? null
                    : () => onSortChanged!(
                        sort == c.pair.$1 ? c.pair.$2 : c.pair.$1,
                      ),
              ),
            ),
          if (showActions) const SizedBox(width: T.s2 + 36),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TableHeaderDelegate old) =>
      old.sort != sort ||
      old.liabilities != liabilities ||
      old.showActions != showActions ||
      old.onSortChanged != onSortChanged;
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
      active
          ? (ascending ? Icons.arrow_upward : Icons.arrow_downward)
          : Icons.unfold_more,
      size: 12,
      color: active ? T.accent : T.text3,
    );
    final cell = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Align(
          alignment: align,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isLeft && onTap != null) arrow,
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: T.label(size: 11, color: active ? T.text1 : T.text2),
                ),
              ),
              if (isLeft && onTap != null) arrow,
            ],
          ),
        ),
      ),
    );
    if (onTap == null) return cell;
    return Tooltip(
      message: active ? '$label（${ascending ? '升序' : '降序'}）' : '$label（点击排序）',
      child: cell,
    );
  }
}

class _TableRow extends ConsumerWidget {
  const _TableRow({
    required this.h,
    required this.alternate,
    required this.onHoldingTap,
    this.onHoldingMenu,
  });

  final HoldingRow h;
  final bool alternate;
  final void Function(HoldingRow) onHoldingTap;
  final void Function(HoldingRow, Offset)? onHoldingMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = AssetType.fromStorage(h.assetType);
    final isLiability = type == AssetType.liability;
    final isAmount = type.isAmountBased;
    final closed = isHoldingClosed(h);
    final marketValue = isAmount ? h.quantity : h.quantity * h.latestPrice;
    final cost = isAmount ? effectiveCostOf(h) : h.quantity * h.costPrice;
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
                // Amount-based holdings store the invested total in costPrice;
                // their realized profit is exactly 0 (see trade_stats.dart).
                amountBasedHoldingIds: isAmount ? {h.id} : const {},
              )[h.id] ??
              0)
        : 0.0;
    final invested = closedTxns
        .where(
          (t) => TransactionType.fromStorage(t.type) == TransactionType.buy,
        )
        .fold(0.0, (a, t) => a + t.amount);
    final realizedPct = closed && !isLiability && invested > 0
        ? realized / invested
        : null;
    final hide = ref.watch(hideAmountsProvider);
    final dash = Text('--', style: T.mono(size: 13, color: T.text3));
    final menu = onHoldingMenu;
    final row = Material(
      color: alternate ? T.surface : T.bg,
      child: InkWell(
        onTap: () => onHoldingTap(h),
        onSecondaryTapUp: menu == null
            ? null
            : (details) => menu(h, details.globalPosition),
        child: Container(
          height: 48,
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
                        style: TextStyle(
                          fontSize: 13,
                          color: closed || h.archived ? T.text3 : T.text1,
                        ),
                      ),
                    ),
                    if (closed) StatusChip(closedHoldingLabel(h)),
                    if (h.archived) const StatusChip('已归档'),
                  ],
                ),
              ),
              if (!isLiability) ...[
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
                        : Text(
                            Formats.smartNum(h.quantity),
                            style: T.mono(size: 13, color: T.text1),
                          ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: isAmount
                        ? dash
                        : Text(
                            Formats.smartNum(h.costPrice),
                            style: T.mono(size: 13, color: T.text1),
                          ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: isAmount || closed
                        ? dash
                        : Text(
                            Formats.smartNum(h.latestPrice),
                            style: T.mono(size: 13, color: T.text1),
                          ),
                  ),
                ),
              ],
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    hide ? '****' : Formats.money(marketValue, h.currency),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.mono(size: 13),
                  ),
                ),
              ),
              if (!isLiability)
                Expanded(
                  flex: 4,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: closed && isAmount
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
                                    style: T.mono(
                                      size: 12,
                                      color: T.changeColor(realized),
                                    ),
                                  ),
                                ],
                                const SizedBox(width: 8),
                                Text(
                                  '已实现',
                                  style: T.mono(size: 10, color: T.text3),
                                ),
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
                                  style: T.mono(
                                    size: 12,
                                    color: T.changeColor(profit),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              if (menu != null) ...[
                const SizedBox(width: T.s2),
                HoldingActionsButton(
                  compact: true,
                  onPressed: (at) => menu(h, at),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (menu == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (details) => menu(h, details.globalPosition),
      child: row,
    );
  }
}
