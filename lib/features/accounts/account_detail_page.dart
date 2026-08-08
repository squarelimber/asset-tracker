import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../data/database.dart';

/// Account detail page: holdings + transactions of one account.
class AccountDetailPage extends ConsumerWidget {
  const AccountDetailPage({super.key, required this.accountId});

  final int accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider(accountId));
    final holdings = ref.watch(holdingsByAccountProvider(accountId));
    final txns = ref.watch(transactionsByAccountProvider(accountId));

    return Scaffold(
      appBar: AppBar(
        title: account.when(
          data: (a) => Text(a?.name ?? '账户'),
          loading: () => const Text('账户'),
          error: (_, _) => const Text('账户'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('持仓', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          holdings.when(
            data: (list) => list.isEmpty
                ? const _Hint('暂无持仓')
                : Column(
                    children: [
                      for (final h in list) ...[
                        _HoldingTile(holding: h),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('加载失败: $e'),
          ),
          const SizedBox(height: 24),
          Text('交易流水', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          txns.when(
            data: (list) => list.isEmpty
                ? const _Hint('暂无流水')
                : Column(
                    children: [
                      for (final t in list) ...[
                        _TransactionTile(txn: t),
                        const SizedBox(height: 4),
                      ],
                    ],
                  ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('加载失败: $e'),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}

class _HoldingTile extends StatelessWidget {
  const _HoldingTile({required this.holding});

  final HoldingRow holding;

  @override
  Widget build(BuildContext context) {
    final type = AssetType.fromStorage(holding.assetType);
    final marketValue =
        type.isAmountBased ? holding.quantity : holding.quantity * holding.latestPrice;
    final cost = type.isAmountBased
        ? (holding.costPrice > 0 ? holding.costPrice : holding.quantity)
        : holding.quantity * holding.costPrice;
    final profit = marketValue - cost;
    final profitPct = cost == 0 ? 0.0 : profit / cost;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: type.color.withValues(alpha: 0.15),
              child: Icon(type.icon, size: 18, color: type.color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(holding.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall),
                  Text(
                    type.isAmountBased
                        ? '持有 ${Formats.holdingDuration(holding.purchaseDate ?? holding.createdAt)}'
                        : '${holding.symbol ?? ''}  ${MarketSource.fromStorage(holding.marketSource).label}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '¥${marketValue.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  '${profit >= 0 ? '+' : ''}¥${profit.toStringAsFixed(2)} (${(profitPct * 100).toStringAsFixed(2)}%)',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: profit >= 0 ? context.upColor() : context.downColor(),
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({required this.txn});

  final TransactionRow txn;

  @override
  Widget build(BuildContext context) {
    final type = TransactionType.fromStorage(txn.type);
    final isIn = type == TransactionType.buy ||
        type == TransactionType.transferIn ||
        type == TransactionType.income ||
        type == TransactionType.dividend;
    return Card(
      child: ListTile(
        leading: Icon(type.icon, color: isIn ? context.upColor() : context.downColor()),
        title: Text(type.label),
        subtitle: Text(
          txn.note == null || txn.note!.isEmpty
              ? Formats.dateTime(txn.occurredAt.toLocal())
              : '${txn.note} · ${Formats.dateTime(txn.occurredAt.toLocal())}',
        ),
        trailing: SizedBox(
          width: 110,
          child: Text(
            '${isIn ? '+' : '-'}¥${Formats.amount(txn.amount)}',
            textAlign: TextAlign.end,
            style: TextStyle(
              color: isIn ? context.upColor() : context.downColor(),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
