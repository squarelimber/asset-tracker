import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../core/history_sync.dart';
import '../../data/database.dart';
import '../tokens.dart';
import 'terminal_card.dart';

/// One transaction row, shared by the holding detail sheet and the unified
/// transaction history page.
///
/// [holdingName] / [accountName] / [counterpartyText] are optional context
/// lines shown in the subtitle (the holding sheet omits them, the history
/// page fills them in, e.g. counterparty "扣款来源：天天宝").
class TransactionTile extends ConsumerWidget {
  const TransactionTile({
    super.key,
    required this.txn,
    this.costPrice,
    this.holdingName,
    this.accountName,
    this.counterpartyText,
  });

  final TransactionRow txn;
  final double? costPrice;
  final String? holdingName;
  final String? accountName;
  final String? counterpartyText;

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
    // Built with plain statements: the null-aware element syntax the
    // analyzer suggests does not parse on the pinned Dart SDK (see
    // AGENTS.md pitfall 2).
    final subtitleParts = <String>[Formats.dateTime(txn.occurredAt.toLocal())];
    if (holdingName != null) subtitleParts.add(holdingName!);
    if (counterpartyText != null) subtitleParts.add(counterpartyText!);
    if (accountName != null) subtitleParts.add(accountName!);
    if (realized != null) {
      subtitleParts.add(
          '落袋 ${realized >= 0 ? '+' : ''}${Formats.money(realized, txn.currency)}');
    }
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
          subtitleParts.join(' · '),
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
