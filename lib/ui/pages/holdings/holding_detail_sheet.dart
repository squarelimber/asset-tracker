import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/nav_history.dart';
import '../../../core/symbols.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../../domain/holding_cost.dart';
import '../../../domain/trade_stats.dart';
import '../../components/error_state.dart';
import '../../components/status_chip.dart';
import '../../components/terminal_card.dart';
import '../../components/transaction_presentation.dart';
import '../../components/transaction_tile.dart';
import '../../tokens.dart';
import 'holding_dialogs.dart';
import 'holdings_page.dart';

class HoldingDetailSheet extends ConsumerWidget {
  const HoldingDetailSheet({
    super.key,
    required this.holding,
  });

  final HoldingRow holding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txns = ref.watch(transactionsByHoldingProvider(holding.id));
    final txnList = txns.valueOrNull ?? const <TransactionRow>[];
    final holdingsById = <int, HoldingRow>{
      if (txnList.any(isTransferRecord))
        for (final row
            in ref.watch(holdingsProvider).valueOrNull ?? const <HoldingRow>[])
          row.id: row,
      holding.id: holding,
    };
    final type = AssetType.fromStorage(holding.assetType);
    // Sold-out: positions with nothing left. Repaid liabilities keep the
    // normal debt view.
    final isClosed = isHoldingClosed(holding) && type != AssetType.liability;
    final marketValue =
        type.isAmountBased ? holding.quantity : holding.quantity * holding.latestPrice;
    final cost = isClosed && type.isAmountBased
        ? 0.0 // Fully redeemed: the principal came back, no residual cost.
        : type.isAmountBased
            ? effectiveCostOf(holding)
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
            // Amount-based holdings store the invested total in costPrice;
            // their realized profit is exactly 0 (see trade_stats.dart).
            amountBasedHoldingIds: type.isAmountBased ? {holding.id} : const {},
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
    final todayRow = cachedQuoteForHolding(cache, holding);
    final source = MarketSource.fromStorage(holding.marketSource);
    final manualHistory = decodeNavHistory(holding.manualNavHistory);
    final manualDate = (manualHistory.keys.toList()..sort()).lastOrNull;
    final valuationQuote = source != MarketSource.manual &&
            !hasManualNav(holding) &&
            todayRow?.price == holding.latestPrice
        ? todayRow
        : null;
    final todayProfit = isClosed || txns.valueOrNull == null
        ? null
        : todayProfitOf(todayRow, holding.quantity, source: source,
            transactions: txnList, holdingId: holding.id);
    return ListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      '持仓信息',
                      overflow: TextOverflow.ellipsis,
                      style: T.mono(
                        size: 15,
                        weight: FontWeight.w600,
                        color: T.text1,
                      ),
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
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(holding.archived ? '已恢复显示' : '已归档')),
                      );
                    }
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
                InfoRow(label: '成本单价', value: Formats.plainNum(holding.costPrice)),
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
                InfoRow(label: '最新单价', value: Formats.plainNum(holding.latestPrice)),
                InfoRow(label: '成本单价', value: Formats.plainNum(holding.costPrice)),
                InfoRow(label: '数量/份额', value: Formats.smartNum(holding.quantity)),
              ],
              InfoRow(label: '币种', value: holding.currency),
              if (!isClosed && !type.isAmountBased && type != AssetType.liability) ...[
                if (manualDate != null && manualHistory[manualDate] == holding.latestPrice)
                  InfoRow(label: '净值日期', value: manualDate)
                else if (valuationQuote != null) ...[
                  if (valuationQuote.quoteDate case final date?)
                    InfoRow(
                      label: type == AssetType.mutualFund ? '净值日期' : '行情日期',
                      value: date,
                    ),
                  InfoRow(
                    label: '行情获取时间',
                    value: Formats.dateTime(valuationQuote.fetchedAt.toLocal()),
                  ),
                ] else
                  const InfoRow(label: '估值来源', value: '账本记录 · 日期未知'),
              ],
              InfoRow(
                label: type == AssetType.liability ? '开卡日期' : '买入日期',
                value: Formats.date(buyDate),
              ),
              if (type != AssetType.liability)
                InfoRow(label: '持有时间', value: Formats.holdingDuration(buyDate, lastSell)),
              if (todayProfit != null)
                InfoRow(
                  label: '最新收益',
                  value: '${todayProfit >= 0 ? '+' : ''}${Formats.money(todayProfit, holding.currency)}',
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
                    for (final t in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _holdingTransaction(t, type, holdingsById),
                      ),
                  ],
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(
            message: '流水加载失败，请重试',
            onRetry: () => ref.invalidate(transactionsByHoldingProvider(holding.id)),
          ),
        ),
      ],
    );
  }

  Widget _holdingTransaction(
    TransactionRow transaction,
    AssetType type,
    Map<int, HoldingRow> holdingsById,
  ) {
    final repayment = repaymentOf(
      transaction,
      holdingsById[transaction.cashSourceId],
      holdingsById[transaction.cashTargetId],
    );
    return TransactionTile(
      txn: transaction,
      // Amount-based holdings store invested principal, not unit cost.
      costPrice: type.isAmountBased ? null : holding.costPrice,
      repaymentLabel: repayment?.label,
      counterpartyText: repayment == null
          ? null
          : '资金来源：${repayment.source.name} · 还款账户：${repayment.target.name}',
    );
  }
}

class InfoRow extends ConsumerWidget {
  const InfoRow({super.key, required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hide = ref.watch(hideAmountsProvider);
    final sensitive = !const {
      '状态', '币种', '清仓日期', '买入日期', '开卡日期', '持有时间', '最新单价',
      '净值日期', '行情日期', '行情获取时间', '估值来源',
    }.contains(label);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label, style: T.mono(size: 13, color: T.text2)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              hide && sensitive ? '****' : value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.mono(
                size: 13,
                weight: FontWeight.w600,
                color: hide && sensitive ? T.text1 : (valueColor ?? T.text1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


