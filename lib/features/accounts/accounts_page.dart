import 'package:drift/drift.dart' hide Column, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../core/history_sync.dart';
import '../../core/responsive.dart';
import '../../data/database.dart';
import '../transactions/transaction_dialogs.dart';

class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('账户')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAccountDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('添加账户'),
      ),
      body: accounts.when(
        data: (list) => list.isEmpty
            ? const _EmptyAccounts()
            : ResponsiveShell(
                // ListView so long account+holding lists stay scrollable.
                child: ListView(
                  children: [
                    Text('共 ${list.length} 个账户', style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 12),
                    for (final account in list) ...[
                      _AccountCard(account: account),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }

  Future<void> _showAccountDialog(BuildContext context, WidgetRef ref) async {
    final nameCtrl = TextEditingController();
    final noteCtrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加账户'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '账户名称',
                  hintText: '如：招商银行 / 华泰证券 / 天天基金',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: '备注（可选）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final dao = ref.read(daoProvider);
              await dao.createAccount(AccountsCompanion.insert(
                name: name,
                type: 'general',
                currency: const Value('CNY'),
                note: noteCtrl.text.trim().isEmpty
                    ? const Value.absent()
                    : Value(noteCtrl.text.trim()),
              ));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    noteCtrl.dispose();
  }
}

class _EmptyAccounts extends StatelessWidget {
  const _EmptyAccounts();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.account_balance_wallet_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          const Text('还没有账户\n点击右下角按钮创建第一个账户', textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.account});

  final AccountRow account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdings = ref.watch(holdingsByAccountProvider(account.id));

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/accounts/${account.id}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor:
                        Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                    child: Icon(Icons.account_balance_wallet_outlined,
                        color: Theme.of(context).colorScheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(account.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text(
                          account.note == null || account.note!.isEmpty
                              ? account.currency
                              : '${account.currency} · ${account.note}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  // Per-account asset total + count.
                  holdings.when(
                    data: (list) => Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '¥${Formats.amount(_accountTotal(list))}',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        Text(
                          '${list.length} 项持仓 · '
                          '${_accountProfit(list) >= 0 ? '+' : ''}¥${Formats.amount(_accountProfit(list))}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: context.changeColor(_accountProfit(list)),
                              ),
                        ),
                      ],
                    ),
                    loading: () => const SizedBox.shrink(),
                    error: (_, _) => const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 4),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'delete') _confirmDelete(context, ref);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('删除账户')),
                    ],
                  ),
                ],
              ),
              // Expanded holding list right inside the account card,
              // so no extra tap into the detail page is needed.
              if (holdings.value != null && holdings.value!.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 4),
                for (final h in holdings.value!) _HoldingMiniTile(holding: h),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Total market value of the account's holdings (per-currency sums).
  static double _accountTotal(List<HoldingRow> list) {
    return list.fold(0.0, (sum, h) {
      final type = AssetType.fromStorage(h.assetType);
      return sum + (type.isAmountBased ? h.quantity : h.quantity * h.latestPrice);
    });
  }

  /// Total profit of the account's holdings.
  static double _accountProfit(List<HoldingRow> list) {
    return list.fold(0.0, (sum, h) {
      final type = AssetType.fromStorage(h.assetType);
      final value =
          type.isAmountBased ? h.quantity : h.quantity * h.latestPrice;
      final cost = type.isAmountBased
          ? (h.costPrice > 0 ? h.costPrice : h.quantity)
          : h.quantity * h.costPrice;
      return sum + (value - cost);
    });
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final holdings = ref.read(holdingsByAccountProvider(account.id)).value ?? const [];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除账户'),
        content: Text(
          '确定删除账户「${account.name}」吗？'
          '${holdings.isEmpty ? '' : '账户内 ${holdings.length} 项持仓及交易流水将一并删除。'}'
          '此操作无法撤销。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.upColor()),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(daoProvider).deleteAccount(account.id);
      ref.read(daoProvider).setSetting(historySyncDirtyKey, historyDirtySet);
    }
  }
}

/// Compact holding row shown inside an account card.
/// Tap opens the transaction dialog directly for that holding.
class _HoldingMiniTile extends ConsumerWidget {
  const _HoldingMiniTile({required this.holding});

  final HoldingRow holding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = AssetType.fromStorage(holding.assetType);
    final marketValue = type.isAmountBased
        ? holding.quantity
        : holding.quantity * holding.latestPrice;
    final cost = type.isAmountBased
        ? (holding.costPrice > 0 ? holding.costPrice : holding.quantity)
        : holding.quantity * holding.costPrice;
    final profit = marketValue - cost;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showHoldingTransactionDialog(context, ref, holding),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: Row(
          children: [
            Icon(type.icon, size: 16, color: type.color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                holding.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              Formats.money(marketValue, holding.currency),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: Text(
                '${profit >= 0 ? '+' : ''}${Formats.money(profit, holding.currency)}',
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.changeColor(profit),
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            const Icon(Icons.chevron_right, size: 16),
          ],
        ),
      ),
    );
  }
}
