import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/history_sync.dart';
import '../../../core/symbols.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../../domain/trade_stats.dart';
import '../../components/status_chip.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';
import '../transaction_dialogs.dart';
import 'holding_dialogs.dart';
import 'holdings_page.dart';

void showHoldingDetailSheet(
  BuildContext context,
  WidgetRef ref,
  HoldingRow holding,
) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => HoldingDetailSheet(
        holding: holding,
        scrollController: controller,
      ),
    ),
  );
}

class HoldingDetailSheet extends ConsumerWidget {
  const HoldingDetailSheet({
    super.key,
    required this.holding,
    required this.scrollController,
  });

  final HoldingRow holding;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txns = ref.watch(transactionsByHoldingProvider(holding.id));
    final txnList = txns.valueOrNull ?? const <TransactionRow>[];
    final type = AssetType.fromStorage(holding.assetType);
    // Sold-out: positions with nothing left. Repaid liabilities keep the
    // normal debt view.
    final isClosed = isHoldingClosed(holding) && type != AssetType.liability;
    final marketValue =
        type.isAmountBased ? holding.quantity : holding.quantity * holding.latestPrice;
    final cost = isClosed && type.isAmountBased
        ? 0.0 // Fully redeemed: the principal came back, no residual cost.
        : type.isAmountBased
            ? (holding.costPrice > 0 ? holding.costPrice : holding.quantity)
            : holding.quantity * holding.costPrice;
    final profit = marketValue - cost;
    final profitPct = cost == 0 ? 0.0 : profit / cost;
    final buyDate = holding.purchaseDate ?? holding.createdAt;
    // For sold-out positions the holding period ends at the last sell.
    final lastSell = isClosed
        ? TradeStatsCalculator.lastSellDate(txnList, holdingId: holding.id)
        : null;
    final days = (lastSell ?? DateTime.now()).difference(buyDate).inDays;
    final annualized = isClosed ? null : Formats.annualizedReturn(profitPct, days);
    // Realized P&L of the sold-out position: per-sell (price - unit cost) x
    // quantity, over the invested amount from buy transactions.
    final realized = isClosed
        ? (TradeStatsCalculator.realizedProfitByHolding(
            txnList,
            {holding.id: holding.costPrice},
          )[holding.id] ??
          0)
        : 0.0;
    final invested = isClosed
        ? txnList
            .where((t) => TransactionType.fromStorage(t.type) == TransactionType.buy)
            .fold(0.0, (a, t) => a + t.amount)
        : 0.0;
    final realizedPct = isClosed && invested > 0 ? realized / invested : null;
    final cache = ref.watch(priceCacheProvider).value ?? const <String, PriceCacheRow>{};
    final cacheSymbol = cacheSymbolFor(holding);
    final todayRow = cacheSymbol == null ? null : cache[cacheSymbol];
    final todayProfit = isClosed ? null : todayProfitOf(todayRow, holding.quantity);
    final todayPct = todayChangePctOf(todayRow);
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      holding.name,
                      overflow: TextOverflow.ellipsis,
                      style: T.mono(size: 18, weight: FontWeight.w700, color: T.text1),
                    ),
                  ),
                  if (isClosed) StatusChip(closedHoldingLabel(holding)),
                  if (holding.archived) const StatusChip('已归档'),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) async {
                switch (v) {
                  case 'edit':
                    showEditHoldingDialog(context, ref, holding);
                  case 'update_price':
                    if (!type.isAmountBased) {
                      showUpdatePriceDialog(context, ref, holding);
                    }
                  case 'archive':
                    await ref.read(daoProvider).setArchived(holding.id, !holding.archived);
                    if (context.mounted) Navigator.of(context).pop();
                  case 'delete':
                    confirmDeleteHolding(context, ref, holding);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('编辑')),
                if (!type.isAmountBased)
                  const PopupMenuItem(value: 'update_price', child: Text('更新单价')),
                PopupMenuItem(
                  value: 'archive',
                  child: Text(holding.archived ? '恢复显示' : '归档'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: () => showHoldingTransactionDialog(context, ref, holding),
              icon: const Icon(Icons.edit_note, size: 18),
              label: const Text('记一笔'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TerminalCard(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              if (type == AssetType.liability)
                // Liabilities have no cost basis / return rate.
                InfoRow(
                  label: '当前欠款',
                  value: Formats.money(marketValue, holding.currency),
                  valueColor: T.down,
                )
              else if (isClosed && type.isAmountBased) ...[
                // Fully redeemed (e.g. a deposit paid out): show it as settled.
                InfoRow(label: '当前金额', value: Formats.money(0, holding.currency)),
                InfoRow(label: '状态', value: '已结清', valueColor: T.text3),
              ] else if (isClosed) ...[
                // Sold-out share-based position: realized P&L instead of
                // live quotes.
                InfoRow(
                  label: '已实现收益',
                  value: '${realized >= 0 ? '+' : ''}${Formats.money(realized, holding.currency)}'
                      '${realizedPct == null ? '' : ' (${Formats.pct(realizedPct)})'}',
                  valueColor: T.changeColor(realized),
                ),
                InfoRow(label: '成本单价', value: holding.costPrice.toStringAsFixed(4)),
                if (lastSell != null)
                  InfoRow(label: '清仓日期', value: Formats.date(lastSell)),
              ] else if (type.isAmountBased) ...[
                InfoRow(label: '当前金额', value: Formats.money(marketValue, holding.currency)),
                InfoRow(label: '累计投入', value: Formats.money(cost, holding.currency)),
                InfoRow(
                  label: '收益',
                  value: '${profitPct >= 0 ? '+' : ''}${Formats.money(profit, holding.currency)}'
                      ' (${Formats.pct(profitPct)})',
                  valueColor: T.changeColor(profit),
                ),
              ] else ...[
                InfoRow(label: '最新单价', value: holding.latestPrice.toStringAsFixed(4)),
                InfoRow(label: '成本单价', value: holding.costPrice.toStringAsFixed(4)),
                InfoRow(label: '数量/份额', value: Formats.smartNum(holding.quantity)),
              ],
              InfoRow(label: '币种', value: holding.currency),
              InfoRow(
                label: type == AssetType.liability ? '开卡日期' : '买入日期',
                value: Formats.date(buyDate),
              ),
              if (type != AssetType.liability)
                InfoRow(label: '持有时间', value: Formats.holdingDuration(buyDate, lastSell)),
              if (todayProfit != null)
                InfoRow(
                  label: '最新收益',
                  value: todayPct == null
                      ? '${todayProfit >= 0 ? '+' : ''}${Formats.money(todayProfit, holding.currency)}'
                      : '${todayProfit >= 0 ? '+' : ''}${Formats.money(todayProfit, holding.currency)}'
                          ' (${Formats.pct(todayPct)})',
                  valueColor: T.changeColor(todayProfit),
                ),
              if (annualized != null && type != AssetType.liability)
                InfoRow(
                  label: '年化收益率',
                  value: Formats.pct(annualized),
                  valueColor: T.changeColor(annualized),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text('交易流水', style: T.mono(size: 15, weight: FontWeight.w600, color: T.text1)),
        const SizedBox(height: 8),
        txns.when(
          data: (list) => list.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: Text('暂无流水')),
                )
              : Column(
                  children: [
                    for (final t in list) ...[
                      TransactionTile(txn: t, costPrice: holding.costPrice),
                      const SizedBox(height: 4),
                    ],
                  ],
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('加载失败: $e'),
        ),
      ],
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label, style: T.mono(size: 13, color: T.text2)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.mono(
                size: 13,
                weight: FontWeight.w600,
                color: valueColor ?? T.text1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TransactionTile extends ConsumerWidget {
  const TransactionTile({super.key, required this.txn, this.costPrice});

  final TransactionRow txn;
  final double? costPrice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = TransactionType.fromStorage(txn.type);
    final isIn = type == TransactionType.buy ||
        type == TransactionType.transferIn ||
        type == TransactionType.income ||
        type == TransactionType.dividend;
    final isSplit = type == TransactionType.split;
    final realized = type == TransactionType.sell &&
            costPrice != null &&
            txn.quantity != null
        ? (txn.price! - costPrice!) * txn.quantity!
        : null;
    return TerminalCard(
      margin: EdgeInsets.zero,
      child: ListTile(
        dense: true,
        leading: Icon(
          type.icon,
          size: 20,
          color: isSplit ? T.text3 : T.changeColor(isIn ? 1 : -1),
        ),
        title: Text(type.label, style: T.mono(size: 13, color: T.text1)),
        subtitle: Text(
          realized == null
              ? Formats.dateTime(txn.occurredAt.toLocal())
              : '${Formats.dateTime(txn.occurredAt.toLocal())} · 落袋 '
                  '${realized >= 0 ? '+' : ''}${Formats.money(realized, txn.currency)}',
          style: T.mono(size: 11, color: T.text3),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                isSplit
                    ? '×${Formats.smartNum(txn.amount)}'
                    : '${isIn ? '+' : '-'}${Formats.money(txn.amount, txn.currency)}',
                textAlign: TextAlign.end,
                style: T.mono(
                  size: 13,
                  weight: FontWeight.w600,
                  color: isSplit ? T.text3 : T.changeColor(isIn ? 1 : -1),
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: '删除流水（自动回滚持仓）',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('删除流水'),
                    content: const Text('删除后持仓会自动回滚到该笔交易前的状态。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: T.up),
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (ok != true || !context.mounted) return;
                final result =
                    await ref.read(transactionServiceProvider).remove(txn.id);
                if (!context.mounted) return;
                if (result.ok) {
                  ref.read(daoProvider).setSetting(historySyncDirtyKey, historyDirtySet);
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(result.ok ? '已删除并回滚' : (result.message ?? '删除失败')),
                    backgroundColor: result.ok ? null : T.up,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
