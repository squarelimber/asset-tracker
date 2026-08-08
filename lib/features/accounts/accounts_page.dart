import 'package:drift/drift.dart' hide Column, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/enums.dart';
import '../../core/responsive.dart';
import '../../data/database.dart';

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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
    final type = ValueNotifier<AssetType>(AssetType.stock);
    final currencyCtrl = TextEditingController(text: 'CNY');
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
                decoration: const InputDecoration(labelText: '账户名称'),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<AssetType>(
                valueListenable: type,
                builder: (context, value, _) => DropdownButtonFormField<AssetType>(
                  initialValue: value,
                  decoration: const InputDecoration(labelText: '账户类型'),
                  items: [
                    for (final t in AssetType.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: (v) => type.value = v ?? AssetType.stock,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: currencyCtrl,
                decoration: const InputDecoration(labelText: '币种 (ISO 代码)'),
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
                type: type.value.storageName,
                currency: Value(currencyCtrl.text.trim().toUpperCase().isEmpty
                    ? 'CNY'
                    : currencyCtrl.text.trim().toUpperCase()),
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
    final assetType = AssetType.fromStorage(account.type);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/accounts/${account.id}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: assetType.color.withValues(alpha: 0.15),
                child: Icon(assetType.icon, color: assetType.color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(account.name,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${assetType.label} · ${account.currency}${account.note == null || account.note!.isEmpty ? '' : ' · ${account.note}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              holdings.when(
                data: (h) => Text('${h.length} 项持仓', style: Theme.of(context).textTheme.bodyMedium),
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
