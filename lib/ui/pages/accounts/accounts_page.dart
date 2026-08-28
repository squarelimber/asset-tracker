import 'package:drift/drift.dart' hide Column, isNull;
import 'package:flutter/material.dart' hide DataRow;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/history_sync.dart';
import '../../../core/responsive.dart';
import '../../../data/database.dart';
import '../../components/app_bar_actions.dart';
import '../../components/data_row.dart';
import '../../components/delta_text.dart';
import '../../components/empty_state.dart';
import '../../components/form_fields.dart';
import '../../components/kpi_grid.dart';
import '../../components/section_header.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';
import '../transaction_dialogs.dart';

class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('账户'),
        actions: const [TerminalAppBarActions()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAccountDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('添加账户'),
      ),
      body: accounts.when(
        data: (list) => list.isEmpty
            ? const EmptyState(message: '还没有账户\n点击右下角按钮创建第一个账户')
            : ResponsiveShell(
                child: ListView(
                  children: [
                    _AccountsKpis(accounts: list),
                    const SizedBox(height: T.s3),
                    for (final account in list) ...[
                      _AccountCard(account: account),
                      const SizedBox(height: T.s3),
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
              TerminalTextField(
                controller: nameCtrl,
                label: '账户名称',
                hint: '如：招商银行 / 华泰证券 / 天天基金',
                autofocus: true,
              ),
              const SizedBox(height: T.s3),
              TerminalTextField(
                controller: noteCtrl,
                label: '备注（可选）',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
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

class _AccountsKpis extends ConsumerWidget {
  const _AccountsKpis({required this.accounts});

  final List<AccountRow> accounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hide = ref.watch(hideAmountsProvider);
    final holdingsLists = <List<HoldingRow>>[
      for (final a in accounts)
        ref.watch(holdingsByAccountProvider(a.id)).value ?? const <HoldingRow>[],
    ];
    return FutureBuilder<Map<String, double>>(
      future: ref.watch(cnyRatesProvider.future),
      builder: (context, snapshot) {
        final rates = snapshot.data ?? const <String, double>{};
        var total = 0.0;
        for (final list in holdingsLists) {
          total += _accountTotal(list, rates);
        }
        return KpiGrid(
          tiles: [
            StatTile(label: '账户数', value: '${accounts.length}'),
            StatTile(
              label: '总余额',
              value: hide ? '****' : '¥${Formats.amount(total)}',
            ),
          ],
        );
      },
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.account});

  final AccountRow account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdings = ref.watch(holdingsByAccountProvider(account.id));
    final hide = ref.watch(hideAmountsProvider);
    final list = holdings.value ?? const <HoldingRow>[];
    return TerminalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FutureBuilder<Map<String, double>>(
            future: ref.watch(cnyRatesProvider.future),
            builder: (context, snapshot) {
              final rates = snapshot.data ?? const <String, double>{};
              final total = _accountTotal(list, rates);
              return SectionHeader(
                label: account.name,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      hide
                          ? '****'
                          : '¥${Formats.amount(total)} · ${list.length} 项',
                      style: T.mono(size: 12, color: T.text1),
                    ),
                    const SizedBox(width: T.s1),
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
              );
            },
          ),
          if (list.isNotEmpty)
            for (final h in list)
              DataRow(
                title: h.name,
                leading: Icon(
                  AssetType.fromStorage(h.assetType).icon,
                  size: 16,
                  color: AssetType.fromStorage(h.assetType).color,
                ),
                trailing: _HoldingMiniTrailing(h: h),
                onTap: () => showHoldingTransactionDialog(context, ref, h),
              ),
          const SizedBox(height: T.s1),
          DataRow(
            title: '账户详情',
            trailing: const SizedBox.shrink(),
            showChevron: true,
            onTap: () => context.push('/accounts/${account.id}'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final holdings =
        ref.read(holdingsByAccountProvider(account.id)).value ?? const [];
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
    if (ok == true) {
      await ref.read(daoProvider).deleteAccount(account.id);
      ref.read(daoProvider).setSetting(historySyncDirtyKey, historyDirtySet);
    }
  }
}

/// Right-hand amounts of a holding mini row inside an account card.
class _HoldingMiniTrailing extends ConsumerWidget {
  const _HoldingMiniTrailing({required this.h});

  final HoldingRow h;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = AssetType.fromStorage(h.assetType);
    final marketValue =
        type.isAmountBased ? h.quantity : h.quantity * h.latestPrice;
    final cost = type.isAmountBased
        ? (h.costPrice > 0 ? h.costPrice : h.quantity)
        : h.quantity * h.costPrice;
    final profit = marketValue - cost;
    final hide = ref.watch(hideAmountsProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          hide ? '****' : Formats.money(marketValue, h.currency),
          style: T.mono(size: 13, weight: FontWeight.w600, color: T.text1),
        ),
        const SizedBox(width: T.s2),
        DeltaText(
          value: profit,
          text: hide
              ? '****'
              : '${profit >= 0 ? '+' : ''}${Formats.money(profit, h.currency)}',
          size: 12,
        ),
      ],
    );
  }
}

/// Total market value of the account's assets (liabilities excluded),
/// converted to CNY.
double _accountTotal(List<HoldingRow> list, Map<String, double> rates) {
  return list.fold(0.0, (sum, h) {
    final type = AssetType.fromStorage(h.assetType);
    if (type == AssetType.liability) return sum;
    final rate = rates[h.currency.toUpperCase()] ?? 1;
    return sum +
        (type.isAmountBased ? h.quantity : h.quantity * h.latestPrice) *
            rate;
  });
}
