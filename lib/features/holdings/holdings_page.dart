import 'package:drift/drift.dart' hide Column, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../data/database.dart';

final _refreshingProvider = StateProvider<bool>((ref) => false);

class HoldingsPage extends ConsumerWidget {
  const HoldingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdings = ref.watch(holdingsProvider);
    final refreshing = ref.watch(_refreshingProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('持仓'),
        actions: [
          IconButton(
            tooltip: '刷新行情',
            onPressed: refreshing ? null : () => _refresh(context, ref),
            icon: refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddHoldingDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('添加持仓'),
      ),
      body: holdings.when(
        data: (list) => list.isEmpty
            ? const _EmptyHoldings()
            : ResponsiveShell(
                child: ResponsiveGrid(
                  children: [
                    for (final h in list) _HoldingCard(holding: h),
                  ],
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    ref.read(_refreshingProvider.notifier).state = true;
    final result = await ref.read(marketServiceProvider).refreshAll();
    ref.read(_refreshingProvider.notifier).state = false;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.failed == 0
            ? '行情已更新 (${result.updated} 项)'
            : '更新 ${result.updated} 项，失败 ${result.failed} 项'),
      ),
    );
  }

  Future<void> _showAddHoldingDialog(BuildContext context, WidgetRef ref) async {
    final accounts = await ref.read(accountsProvider.future);
    if (accounts.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在"账户"页创建一个账户')),
        );
      }
      return;
    }
    if (!context.mounted) return;

    final accountId = ValueNotifier<int?>(accounts.first.id);
    final assetType = ValueNotifier<AssetType>(AssetType.stock);
    final nameCtrl = TextEditingController();
    final symbolCtrl = TextEditingController();
    final quantityCtrl = TextEditingController();
    final costPriceCtrl = TextEditingController();
    final currencyCtrl = TextEditingController(text: 'CNY');

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加持仓'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<int?>(
                valueListenable: accountId,
                builder: (context, value, _) => DropdownButtonFormField<int>(
                  initialValue: value,
                  decoration: const InputDecoration(labelText: '所属账户'),
                  items: [
                    for (final a in accounts)
                      DropdownMenuItem(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: (v) => accountId.value = v,
                ),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<AssetType>(
                valueListenable: assetType,
                builder: (context, value, _) => DropdownButtonFormField<AssetType>(
                  initialValue: value,
                  decoration: const InputDecoration(labelText: '资产类型'),
                  items: [
                    for (final t in AssetType.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: (v) => assetType.value = v ?? AssetType.stock,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<AssetType>(
                valueListenable: assetType,
                builder: (context, type, _) {
                  final symbolEnabled = type.isMarketLinked ||
                      type == AssetType.bankWealth;
                  return TextField(
                    controller: symbolCtrl,
                    decoration: InputDecoration(
                      labelText: symbolEnabled ? '行情代码' : '（手动净值资产无需代码）',
                      hintText: switch (type) {
                        AssetType.stock || AssetType.etf => '如 sh600519 / sz159915',
                        AssetType.mutualFund => '如 110022',
                        AssetType.gold => 'AU99.99（自动金价）',
                        AssetType.crypto => '如 bitcoin',
                        AssetType.bankWealth => '填外汇代码如 USD 可自动汇率联动，留空手动净值',
                        _ => null,
                      },
                    ),
                    enabled: symbolEnabled,
                  );
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: quantityCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '数量 / 份额 / 克数'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: costPriceCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '成本单价'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: currencyCtrl,
                decoration: const InputDecoration(labelText: '币种 (ISO 代码)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final qty = double.tryParse(quantityCtrl.text.trim());
              final cost = double.tryParse(costPriceCtrl.text.trim());
              if (name.isEmpty || qty == null || cost == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请填写名称、数量、成本单价')),
                );
                return;
              }
              final dao = ref.read(daoProvider);
              final type = assetType.value;
              final symbol = symbolCtrl.text.trim();
              final marketSource = switch (type) {
                AssetType.stock || AssetType.etf => 'sina',
                AssetType.mutualFund => 'eastmoney',
                AssetType.gold => 'sge',
                AssetType.crypto => 'coingecko',
                AssetType.bankWealth when symbol.isNotEmpty => 'forex',
                _ => 'manual',
              };
              await dao.createHolding(HoldingsCompanion.insert(
                accountId: accountId.value!,
                name: name,
                assetType: type.storageName,
                marketSource: Value(marketSource),
                symbol: symbol.isNotEmpty ? Value(symbol) : const Value.absent(),
                quantity: Value(qty),
                costPrice: Value(cost),
                currency: Value(currencyCtrl.text.trim().toUpperCase().isEmpty
                    ? 'CNY'
                    : currencyCtrl.text.trim().toUpperCase()),
              ));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    symbolCtrl.dispose();
    quantityCtrl.dispose();
    costPriceCtrl.dispose();
    currencyCtrl.dispose();
  }
}

class _EmptyHoldings extends StatelessWidget {
  const _EmptyHoldings();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.pie_chart_outline, size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          const Text('还没有持仓\n点击右下角按钮添加第一个持仓', textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _HoldingCard extends ConsumerWidget {
  const _HoldingCard({required this.holding});

  final HoldingRow holding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = AssetType.fromStorage(holding.assetType);
    final marketValue = holding.quantity * holding.latestPrice;
    final cost = holding.quantity * holding.costPrice;
    final profit = marketValue - cost;
    final profitPct = cost == 0 ? 0.0 : profit / cost;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showDetail(context, ref),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: type.color.withValues(alpha: 0.15),
                    child: Icon(type.icon, size: 18, color: type.color),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(holding.name, style: Theme.of(context).textTheme.titleMedium),
                        Text(
                          holding.symbol ?? '手动净值',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      switch (v) {
                        case 'edit':
                          _showEditDialog(context, ref);
                        case 'update_price':
                          _showUpdatePriceDialog(context, ref);
                        case 'delete':
                          _confirmDelete(context, ref);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('编辑')),
                      const PopupMenuItem(value: 'update_price', child: Text('更新单价')),
                      const PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '¥${Formats.amount(marketValue)}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    '${profit >= 0 ? '+' : ''}${Formats.amount(profit)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: context.changeColor(profit),
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '(${Formats.pct(profitPct)})',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.changeColor(profit),
                        ),
                  ),
                  const Spacer(),
                  Text('成本 ${Formats.amount(cost)}', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDetail(BuildContext context, WidgetRef ref) async {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, controller) => _HoldingDetailSheet(
          holding: holding,
          scrollController: controller,
        ),
      ),
    );
  }

  Future<void> _showUpdatePriceDialog(BuildContext context, WidgetRef ref) async {
    final priceCtrl = TextEditingController(
      text: holding.latestPrice > 0 ? holding.latestPrice.toString() : '',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('更新单价'),
        content: TextField(
          controller: priceCtrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '最新单价'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final price = double.tryParse(priceCtrl.text.trim());
              if (price == null || price <= 0) return;
              Navigator.pop(context, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final price = double.tryParse(priceCtrl.text.trim());
      if (price != null && price > 0) {
        await ref.read(daoProvider).updateHoldingPrice(holding.id, price);
      }
    }
    priceCtrl.dispose();
  }

  Future<void> _showEditDialog(BuildContext context, WidgetRef ref) async {
    final nameCtrl = TextEditingController(text: holding.name);
    final quantityCtrl =
        TextEditingController(text: holding.quantity.toString());
    final costCtrl = TextEditingController(text: holding.costPrice.toString());
    final priceCtrl =
        TextEditingController(text: holding.latestPrice.toString());
    final noteCtrl = TextEditingController(text: holding.note ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑持仓'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '名称')),
              const SizedBox(height: 12),
              TextField(
                controller: quantityCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '数量 / 份额 / 克数'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: costCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '成本单价'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '最新单价'),
              ),
              const SizedBox(height: 12),
              TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: '备注')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (ok == true) {
      final qty = double.tryParse(quantityCtrl.text.trim());
      final cost = double.tryParse(costCtrl.text.trim());
      final price = double.tryParse(priceCtrl.text.trim());
      if (qty == null || cost == null || price == null) return;
      await ref.read(daoProvider).updateHolding(
        holding.copyWith(
          name: nameCtrl.text.trim().isEmpty ? holding.name : nameCtrl.text.trim(),
          quantity: qty,
          costPrice: cost,
          latestPrice: price,
          note: noteCtrl.text.trim().isEmpty ? const Value.absent() : Value(noteCtrl.text.trim()),
        ),
      );
    }
    nameCtrl.dispose();
    quantityCtrl.dispose();
    costCtrl.dispose();
    priceCtrl.dispose();
    noteCtrl.dispose();
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除持仓'),
        content: Text('确定删除「${holding.name}」吗？相关交易流水也会被删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.up),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(daoProvider).deleteHolding(holding.id);
    }
  }
}

class _HoldingDetailSheet extends ConsumerWidget {
  const _HoldingDetailSheet({required this.holding, required this.scrollController});

  final HoldingRow holding;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txns = ref.watch(transactionsByHoldingProvider(holding.id));
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Text(holding.name, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _InfoRow(label: '最新单价', value: holding.latestPrice.toStringAsFixed(4)),
                _InfoRow(label: '成本单价', value: holding.costPrice.toStringAsFixed(4)),
                _InfoRow(label: '数量/份额', value: Formats.smartNum(holding.quantity)),
                _InfoRow(label: '币种', value: holding.currency),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('交易流水', style: Theme.of(context).textTheme.titleMedium),
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
                      _TransactionTile(txn: t),
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

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        ],
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
        dense: true,
        leading: Icon(type.icon, size: 20, color: context.changeColor(isIn ? 1 : -1)),
        title: Text(type.label),
        subtitle: Text(Formats.dateTime(txn.occurredAt.toLocal())),
        trailing: Text(
          '${isIn ? '+' : '-'}${Formats.amount(txn.amount)}',
          style: TextStyle(
            color: context.changeColor(isIn ? 1 : -1),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
