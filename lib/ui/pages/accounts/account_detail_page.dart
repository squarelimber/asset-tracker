import 'package:flutter/material.dart' hide DataRow;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/history_sync.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../../domain/holding_cost.dart';
import '../../components/app_bar_actions.dart';
import '../../components/data_row.dart';
import '../../components/delta_text.dart';
import '../../components/empty_state.dart';
import '../../components/error_state.dart';
import '../../components/status_chip.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';
import '../transaction_dialogs.dart';

/// Account detail page: holdings + transactions of one account.
class AccountDetailPage extends ConsumerWidget {
  const AccountDetailPage({super.key, required this.accountId});

  final int accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider(accountId));
    final holdings = ref.watch(holdingsByAccountProvider(accountId));
    final txns = ref.watch(transactionsByAccountProvider(accountId));
    final allHoldings =
        ref.watch(holdingsProvider).valueOrNull ?? const <HoldingRow>[];
    final accounts =
        ref.watch(accountsProvider).valueOrNull ?? const <AccountRow>[];
    final holdingsById = {for (final h in allHoldings) h.id: h};
    final accountNames = {for (final a in accounts) a.id: a.name};

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: account.when(
            data: (a) => Text(a?.name ?? '账户'),
            loading: () => const Text('账户'),
            error: (_, _) => const Text('账户'),
          ),
          actions: [
            IconButton(
              tooltip: '记流水',
              icon: const Icon(Icons.edit_note),
              onPressed: () =>
                  showAccountTransactionDialog(context, ref, accountId),
            ),
            const TerminalAppBarActions(),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '持仓'),
              Tab(text: '交易流水'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            RefreshIndicator(
              onRefresh: () async =>
                  ref.invalidate(holdingsByAccountProvider(accountId)),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(T.s3),
                children: [
                  holdings.when(
                    data: (list) => list.isEmpty
                        ? const EmptyState(message: '暂无持仓')
                        : Column(
                            children: [
                              for (final h in list) ...[
                                _HoldingRow(h: h),
                                const SizedBox(height: T.s1),
                              ],
                            ],
                          ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => ErrorState(
                      message: '持仓加载失败，请重试',
                      onRetry: () =>
                          ref.invalidate(holdingsByAccountProvider(accountId)),
                    ),
                  ),
                ],
              ),
            ),
            RefreshIndicator(
              onRefresh: () async =>
                  ref.invalidate(transactionsByAccountProvider(accountId)),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(T.s3),
                children: [
                  txns.when(
                    data: (list) => list.isEmpty
                        ? const EmptyState(message: '暂无流水')
                        : Column(
                            children: [
                              for (final t in list) ...[
                                _TransactionRow(
                                  txn: t,
                                  accountId: accountId,
                                  holdingsById: holdingsById,
                                  accountNames: accountNames,
                                ),
                              ],
                            ],
                          ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => ErrorState(
                      message: '流水加载失败，请重试',
                      onRetry: () => ref.invalidate(
                        transactionsByAccountProvider(accountId),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoldingRow extends ConsumerWidget {
  const _HoldingRow({required this.h});

  final HoldingRow h;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = AssetType.fromStorage(h.assetType);
    final marketValue = type.isAmountBased
        ? h.quantity
        : h.quantity * h.latestPrice;
    final cost = type.isAmountBased
        ? effectiveCostOf(h)
        : h.quantity * h.costPrice;
    final profit = marketValue - cost;
    final profitPct = cost == 0 ? 0.0 : profit / cost;
    final hide = ref.watch(hideAmountsProvider);
    final closed = isHoldingClosed(h);
    return DataRow(
      title: h.name,
      titleSuffix: closed
          ? StatusChip(closedHoldingLabel(h))
          : (h.archived ? const StatusChip('已归档') : null),
      dimmed: closed || h.archived,
      leading: Icon(type.icon, size: 16, color: type.color),
      subtitle: Text(
        type == AssetType.liability
            ? '负债 · 起始 ${Formats.date(h.purchaseDate ?? h.createdAt)}'
            : type.isAmountBased
            ? '持有 ${Formats.holdingDuration(h.purchaseDate ?? h.createdAt)}'
            : '${h.symbol ?? ''}  ${MarketSource.fromStorage(h.marketSource).label}',
        style: T.label(size: 11, color: T.text3),
      ),
      trailing: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.48,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                hide ? '****' : Formats.money(marketValue, h.currency),
                style: T.mono(
                  size: 13,
                  weight: FontWeight.w600,
                  color: T.text1,
                ),
              ),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: DeltaText(
                value: profit,
                text: hide
                    ? '****'
                    : '${profit >= 0 ? '+' : ''}${Formats.money(profit, h.currency)} (${Formats.pct(profitPct)})',
                size: 12,
              ),
            ),
          ],
        ),
      ),
      onTap: () => showHoldingTransactionDialog(context, ref, h),
    );
  }
}

class _TransactionRow extends ConsumerWidget {
  const _TransactionRow({
    required this.txn,
    required this.accountId,
    required this.holdingsById,
    required this.accountNames,
  });

  final TransactionRow txn;
  final int accountId;
  final Map<int, HoldingRow> holdingsById;
  final Map<int, String> accountNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = TransactionType.fromStorage(txn.type);
    final isTransfer =
        type == TransactionType.transferIn ||
        type == TransactionType.transferOut;
    final sourceInAccount =
        holdingsById[txn.cashSourceId]?.accountId == accountId;
    final targetInAccount =
        holdingsById[txn.cashTargetId]?.accountId == accountId;
    final directionKnown =
        holdingsById[txn.cashSourceId] != null &&
        holdingsById[txn.cashTargetId] != null &&
        (sourceInAccount || targetInAccount);
    final isInternal = isTransfer && sourceInAccount && targetInAccount;
    final neutralTransfer = isTransfer && (!directionKnown || isInternal);
    final isIn = isTransfer && sourceInAccount != targetInAccount
        ? targetInAccount
        : type == TransactionType.buy ||
              type == TransactionType.transferIn ||
              type == TransactionType.income ||
              type == TransactionType.dividend;
    final label = isInternal
        ? '账户内转账'
        : isTransfer && !directionKnown
        ? '转账'
        : isTransfer && sourceInAccount != targetInAccount
        ? (isIn ? '转入' : '转出')
        : type.label;
    final color = neutralTransfer ? T.text2 : (isIn ? T.up : T.down);
    final hide = ref.watch(hideAmountsProvider);
    String? holdingName(int? id) {
      final holding = holdingsById[id];
      if (holding == null) return null;
      final accountName = accountNames[holding.accountId];
      return accountName == null
          ? holding.name
          : '$accountName / ${holding.name}';
    }

    final product = holdingName(txn.holdingId);
    final source = holdingName(txn.cashSourceId);
    final target = holdingName(txn.cashTargetId);
    final targetLabel = switch (type) {
      TransactionType.expense => '扣款',
      TransactionType.income ||
      TransactionType.dividend ||
      TransactionType.sell => '入账',
      _ => '去向',
    };
    final contextParts = <String>[];
    if (product != null) contextParts.add(product);
    contextParts.addAll([
      if (source != null) '来源 $source',
      if (target != null) '$targetLabel $target',
      if (txn.note != null && txn.note!.isNotEmpty) txn.note!,
      Formats.dateTime(txn.occurredAt.toLocal()),
    ]);
    return TerminalCard(
      margin: const EdgeInsets.only(bottom: T.s2),
      padding: const EdgeInsets.symmetric(horizontal: T.s3, vertical: T.s2),
      child: Row(
        children: [
          Icon(
            isTransfer && !neutralTransfer
                ? (isIn ? Icons.south_west : Icons.north_east)
                : neutralTransfer
                ? Icons.swap_horiz
                : type.icon,
            size: 16,
            color: color,
          ),
          const SizedBox(width: T.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: T.mono(size: 13, color: T.text1)),
                Text(
                  contextParts.join(' · '),
                  style: T.label(size: 11, color: T.text3),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.32,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                hide
                    ? '****'
                    : '${neutralTransfer ? '' : (isIn ? '+' : '-')}${Formats.money(txn.amount, txn.currency)}',
                style: T.mono(size: 13, weight: FontWeight.w600, color: color),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: '删除流水（自动回滚持仓）',
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
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
    final result = await ref.read(transactionServiceProvider).remove(txn.id);
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
  }
}
