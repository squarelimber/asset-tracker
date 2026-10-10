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
import '../../components/empty_state.dart';
import '../../components/error_state.dart';
import '../../components/form_fields.dart';
import '../../components/terminal_card.dart';
import '../../components/terminal_fab.dart';
import '../../tokens.dart';

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
      floatingActionButton: TerminalFab(
        onPressed: () => _showAccountDialog(context, ref),
        icon: Icons.add,
        label: '添加账户',
      ),
      body: accounts.when(
        data: (list) => list.isEmpty
            ? const EmptyState(message: '还没有账户\n点击右下角按钮创建第一个账户')
            : ResponsiveShell(
                child: RefreshIndicator(
                  onRefresh: () async => ref.invalidate(accountsProvider),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      for (final account in list) ...[
                        _AccountCard(account: account),
                        const SizedBox(height: T.s3),
                      ],
                    ],
                  ),
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(
          message: '账户数据加载失败，请重试',
          onRetry: () => ref.invalidate(accountsProvider),
        ),
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
              TerminalTextField(controller: noteCtrl, label: '备注（可选）'),
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
              await dao.createAccount(
                AccountsCompanion.insert(
                  name: name,
                  type: 'general',
                  currency: const Value('CNY'),
                  note: noteCtrl.text.trim().isEmpty
                      ? const Value.absent()
                      : Value(noteCtrl.text.trim()),
                ),
              );
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

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.account});

  final AccountRow account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdings = ref.watch(holdingsByAccountProvider(account.id));
    final hide = ref.watch(hideAmountsProvider);
    final list = holdings.value ?? const <HoldingRow>[];
    return TerminalCard(
      child: FutureBuilder<Map<String, double>>(
        future: ref.watch(cnyRatesProvider.future),
        builder: (context, snapshot) {
          final rates = snapshot.data ?? const <String, double>{};
          final total = _accountTotal(list, rates);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 账户名 + 总市值 + 删除菜单（KPI 大卡已删，紧凑一行为主）。
              Row(
                children: [
                  Expanded(
                    child: Text(
                      account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: T.text1,
                      ),
                    ),
                  ),
                  Text(
                    hide
                        ? '****'
                        : '¥${Formats.money(total)} · ${list.length} 项',
                    style: T.mono(size: 12, color: T.text2),
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
              if (list.isNotEmpty) ...[
                const SizedBox(height: T.s2),
                // 资产类型占比条（紧凑一行，替代逐持仓列表）。
                _AccountTypeBar(holdings: list, rates: rates, hide: hide),
              ],
              const SizedBox(height: T.s1),
              // 「账户详情」入口（持仓明细与交易流水都收敛到这里）。
              InkWell(
                onTap: () => context.push('/accounts/${account.id}'),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: T.s1),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '账户详情（持仓 · 流水）',
                          style: TextStyle(fontSize: 12, color: T.text3),
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 16, color: T.text3),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
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

/// 单行占比条：按资产类型聚合市值，展示每类占比与颜色。
class _AccountTypeBar extends StatelessWidget {
  const _AccountTypeBar({
    required this.holdings,
    required this.rates,
    required this.hide,
  });

  final List<HoldingRow> holdings;
  final Map<String, double> rates;
  final bool hide;

  @override
  Widget build(BuildContext context) {
    // Aggregate by high-level category (股票/黄金/债券/现金/…).
    final byCat = <AssetCategory, double>{};
    for (final h in holdings) {
      final cat = AssetType.fromStorage(h.assetType).category;
      byCat[cat] = (byCat[cat] ?? 0) + _amountValue(h, rates);
    }
    final entries = byCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold(0.0, (s, e) => s + e.value);
    if (total <= 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                for (final e in entries)
                  Expanded(
                    flex: (e.value / total * 1000).round().clamp(0, 1000),
                    child: Container(color: e.key.color),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: T.s3,
          runSpacing: 2,
          children: [
            for (final e in entries)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: e.key.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${e.key.label} '
                    '${Formats.pct(total == 0 ? 0 : e.value / total)}',
                    style: T.mono(size: 11, color: T.text2),
                  ),
                  if (!hide) ...[
                    const SizedBox(width: 2),
                    Text(
                      Formats.amountCompact(e.value),
                      style: T.mono(size: 11, color: T.text3),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// Market value of a single holding in CNY (liabilities excluded by caller).
double _amountValue(HoldingRow h, Map<String, double> rates) {
  final type = AssetType.fromStorage(h.assetType);
  final rate = rates[h.currency.toUpperCase()] ?? 1;
  return (type.isAmountBased ? h.quantity : h.quantity * h.latestPrice) * rate;
}

/// Total market value of the account's assets (liabilities excluded),
/// converted to CNY.
double _accountTotal(List<HoldingRow> list, Map<String, double> rates) {
  return list.fold(0.0, (sum, h) {
    final type = AssetType.fromStorage(h.assetType);
    if (type == AssetType.liability) return sum;
    return sum + _amountValue(h, rates);
  });
}
