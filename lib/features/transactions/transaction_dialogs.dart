import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../data/database.dart';

/// Dialog for recording a transaction against a specific holding.
/// Available types follow the holding's nature:
/// - share-based (stocks/funds/gold/wealth/crypto): buy / sell / dividend
/// - amount-based (cash/deposit/liquid wealth): income / expense /
///   transfer in / transfer out
Future<void> showHoldingTransactionDialog(
  BuildContext context,
  WidgetRef ref,
  HoldingRow holding,
) async {
  final holdings = ref.read(holdingsProvider).value ?? const [];
  final type = AssetType.fromStorage(holding.assetType);
  final isShare = type.isMarketLinked || type == AssetType.bankWealth;

  // Money holdings usable as the counterparty for transfers.
  final moneyHoldings = holdings
      .where((h) {
        final t = AssetType.fromStorage(h.assetType);
        return (t.isAmountBased || t == AssetType.liability) && h.id != holding.id;
      })
      .toList();

  // Available transaction types for this holding.
  final available = isShare
      ? <TransactionType>[TransactionType.buy, TransactionType.sell, TransactionType.dividend]
      : <TransactionType>[
          TransactionType.income,
          TransactionType.expense,
          TransactionType.transferIn,
          TransactionType.transferOut,
        ];

  final txnType = ValueNotifier<TransactionType>(available.first);
  final qtyCtrl = TextEditingController();
  final priceCtrl = TextEditingController();
  final amountCtrl = TextEditingController();
  final cashId = ValueNotifier<int?>(moneyHoldings.isEmpty ? null : moneyHoldings.first.id);
  final noteCtrl = TextEditingController();

  String? validate() {
    final t = txnType.value;
    if (isShare && t == TransactionType.dividend) {
      if (amountCtrl.text.trim().isEmpty) return '请填写分红金额';
      if (cashId.value == null) return '请选择入账现金持仓';
      return null;
    }
    if (t == TransactionType.income ||
        t == TransactionType.expense ||
        t == TransactionType.transferIn ||
        t == TransactionType.transferOut) {
      if (amountCtrl.text.trim().isEmpty) return '请填写金额';
      if ((t == TransactionType.transferIn ||
              t == TransactionType.transferOut) &&
          cashId.value == null) {
        return '请选择对方持仓';
      }
      return null;
    }
    if (qtyCtrl.text.trim().isEmpty || priceCtrl.text.trim().isEmpty) {
      return '请填写数量和单价';
    }
    return null;
  }

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
      title: Text('记一笔 · ${holding.name}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<TransactionType>(
              valueListenable: txnType,
              builder: (context, value, _) => SegmentedButton<TransactionType>(
                segments: [
                  for (final t in available)
                    ButtonSegment(value: t, label: Text(t.label)),
                ],
                selected: {value},
                onSelectionChanged: (s) => setState(() => txnType.value = s.first),
              ),
            ),
            const SizedBox(height: 16),
            if (isShare && txnType.value != TransactionType.dividend) ...[
              TextField(
                controller: qtyCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '数量 / 份额 / 克数'),
                onChanged: (_) => syncAmount(qtyCtrl, priceCtrl, amountCtrl),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '单价'),
                onChanged: (_) => syncAmount(qtyCtrl, priceCtrl, amountCtrl),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '金额（自动 = 数量 × 单价，可改）'),
              ),
              if (txnType.value == TransactionType.sell) ...[
                const SizedBox(height: 8),
                ValueListenableBuilder<TransactionType>(
                  valueListenable: txnType,
                  builder: (context, _, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '预计落袋收益：${sellProfitText(qtyCtrl, priceCtrl, holding)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ] else ...[
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: switch (txnType.value) {
                    TransactionType.dividend => '分红金额',
                    TransactionType.income => '收入金额',
                    TransactionType.expense => '支出金额',
                    TransactionType.transferIn => '转入金额',
                    TransactionType.transferOut => '转出金额',
                    _ => '金额',
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (moneyHoldings.isNotEmpty) ...[
              ValueListenableBuilder<int?>(
                valueListenable: cashId,
                builder: (context, value, _) => DropdownButtonFormField<int>(
                  initialValue: value,
                  decoration: InputDecoration(labelText: counterpartyLabel(txnType.value, isShare)),
                  items: [
                    for (final c in moneyHoldings)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text(
                          '${c.name} (${AssetType.fromStorage(c.assetType).label})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => cashId.value = v,
                ),
              ),
              if (isShare && txnType.value != TransactionType.dividend)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      txnType.value == TransactionType.buy
                          ? '不选则不联动扣款'
                          : '不选则卖出回款不入账',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
            ],
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
            final error = validate();
            if (error != null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
              return;
            }
            final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
            final qty = double.tryParse(qtyCtrl.text.trim());
            final price = double.tryParse(priceCtrl.text.trim());
            final t = txnType.value;
            final result = await ref.read(transactionServiceProvider).record(
              accountId: holding.accountId,
              holdingId: isShare ? holding.id : null,
              type: t,
              quantity: isShare && t != TransactionType.dividend ? qty : null,
              price: isShare && t != TransactionType.dividend ? price : null,
              amount: amount,
              cashSourceId: switch (t) {
                TransactionType.buy => cashId.value,
                TransactionType.expense => holding.id,
                TransactionType.transferIn => cashId.value,
                TransactionType.transferOut => holding.id,
                _ => null,
              },
              cashTargetId: switch (t) {
                TransactionType.sell || TransactionType.dividend => cashId.value,
                TransactionType.income => holding.id,
                TransactionType.transferIn => holding.id,
                TransactionType.transferOut => cashId.value,
                _ => null,
              },
              note: noteCtrl.text.trim(),
            );
            if (!context.mounted) return;
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(result.ok ? '已记录' : (result.message ?? '记录失败')),
                backgroundColor: result.ok ? null : AppColors.up,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    ),
    ),
  );
  qtyCtrl.dispose();
  priceCtrl.dispose();
  amountCtrl.dispose();
  noteCtrl.dispose();
}

String sellProfitText(
  TextEditingController qtyCtrl,
  TextEditingController priceCtrl,
  HoldingRow holding,
) {
  final qty = double.tryParse(qtyCtrl.text.trim());
  final price = double.tryParse(priceCtrl.text.trim());
  if (qty == null || price == null) return '--';
  final profit = (price - holding.costPrice) * qty;
  return '${profit >= 0 ? '+' : ''}¥${Formats.amount(profit)}';
}

/// Label of the counterparty dropdown for the current transaction type.
String counterpartyLabel(TransactionType t, bool isShare) {
  if (isShare) {
    return switch (t) {
      TransactionType.buy => '扣款来源（可选）',
      TransactionType.sell => '入账目标（可选）',
      _ => '入账现金持仓',
    };
  }
  return switch (t) {
    TransactionType.income || TransactionType.expense => '关联对方持仓（可选）',
    TransactionType.transferIn => '资金来源持仓',
    TransactionType.transferOut => '资金去向持仓',
    _ => '对方持仓',
  };
}

void syncAmount(
  TextEditingController qtyCtrl,
  TextEditingController priceCtrl,
  TextEditingController amountCtrl,
) {
  final qty = double.tryParse(qtyCtrl.text.trim());
  final price = double.tryParse(priceCtrl.text.trim());
  if (qty != null && price != null) {
    amountCtrl.text = (qty * price).toStringAsFixed(2);
  }
}

/// Dialog for recording account-level flows
/// (transfer/repayment, income, expense).
Future<void> showAccountTransactionDialog(
  BuildContext context,
  WidgetRef ref,
  int accountId,
) async {
  final holdings = ref.read(holdingsProvider).value ?? const [];
  final moneyHoldings = holdings
      .where((h) {
        final t = AssetType.fromStorage(h.assetType);
        return t.isAmountBased || t == AssetType.liability;
      })
      .toList();
  if (moneyHoldings.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('需要先添加现金/存款类持仓才能记流水')),
    );
    return;
  }

  final txnType = ValueNotifier<TransactionType>(TransactionType.transferOut);
  final sourceId = ValueNotifier<int?>(moneyHoldings.first.id);
  final targetId = ValueNotifier<int?>(moneyHoldings.length > 1 ? moneyHoldings[1].id : null);
  final amountCtrl = TextEditingController();
  final noteCtrl = TextEditingController();

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
      title: const Text('记流水'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<TransactionType>(
              valueListenable: txnType,
              builder: (context, value, _) => SegmentedButton<TransactionType>(
                segments: const [
                  ButtonSegment(value: TransactionType.transferOut, label: Text('转账/还款')),
                  ButtonSegment(value: TransactionType.income, label: Text('收入')),
                  ButtonSegment(value: TransactionType.expense, label: Text('支出')),
                ],
                selected: {value},
                onSelectionChanged: (s) => setState(() => txnType.value = s.first),
              ),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<TransactionType>(
              valueListenable: txnType,
              builder: (context, value, _) {
                if (value == TransactionType.transferOut) {
                  return Column(
                    children: [
                      MoneyDropdown(
                        label: '资金来源（现金转出 / 负债还款）',
                        holdings: moneyHoldings,
                        value: sourceId,
                      ),
                      const SizedBox(height: 12),
                      MoneyDropdown(
                        label: '资金去向（现金转入 / 负债还款）',
                        holdings: moneyHoldings,
                        value: targetId,
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '从现金转到负债 = 还款；从负债转到现金 = 借款',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  );
                }
                return MoneyDropdown(
                  label: value == TransactionType.income ? '收入入账持仓' : '支出扣款持仓',
                  holdings: moneyHoldings,
                  value: sourceId,
                );
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '金额'),
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
            final amount = double.tryParse(amountCtrl.text.trim());
            if (amount == null || amount <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请填写有效金额')),
              );
              return;
            }
            final txnTypeValue = txnType.value;
            if (txnTypeValue == TransactionType.transferOut && targetId.value == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请选择资金去向')),
              );
              return;
            }
            final result = await ref.read(transactionServiceProvider).record(
              accountId: accountId,
              type: txnTypeValue,
              amount: amount,
              cashSourceId:
                  txnTypeValue == TransactionType.transferOut ? sourceId.value : null,
              cashTargetId: txnTypeValue == TransactionType.transferOut
                  ? targetId.value
                  : sourceId.value,
              note: noteCtrl.text.trim(),
            );
            if (!context.mounted) return;
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(result.ok ? '已记录' : (result.message ?? '记录失败')),
                backgroundColor: result.ok ? null : AppColors.up,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    ),
    ),
  );
  amountCtrl.dispose();
  noteCtrl.dispose();
}

class MoneyDropdown extends StatelessWidget {
  const MoneyDropdown({
    super.key,
    required this.label,
    required this.holdings,
    required this.value,
  });

  final String label;
  final List<HoldingRow> holdings;
  final ValueNotifier<int?> value;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int?>(
      valueListenable: value,
      builder: (context, current, _) => DropdownButtonFormField<int>(
        initialValue: current,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final h in holdings)
            DropdownMenuItem(
              value: h.id,
              child: Text(
                '${h.name} (${AssetType.fromStorage(h.assetType).label})',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) => value.value = v,
      ),
    );
  }
}
