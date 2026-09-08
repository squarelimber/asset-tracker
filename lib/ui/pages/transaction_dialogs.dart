import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../core/history_sync.dart';
import '../../data/database.dart';
import '../components/form_fields.dart';
import '../tokens.dart';

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
  final isLiability = type == AssetType.liability;

  // Money holdings usable as the counterparty for transfers.
  final moneyHoldings = holdings
      .where((h) {
        final t = AssetType.fromStorage(h.assetType);
        return (t.isAmountBased || t == AssetType.liability) && h.id != holding.id;
      })
      .toList();

  // Cash holdings (amount-based only) usable as the sell/dividend credit
  // target for a share-based holding.
  final cashHoldings = holdings
      .where((h) {
        final t = AssetType.fromStorage(h.assetType);
        return t.isAmountBased && h.id != holding.id;
      })
      .toList();

  // Holdings usable as the funding source for a buy: cash holdings plus
  // share-based holdings with a positive balance (e.g. a money-market fund
  // redeemed to buy a new product). Liabilities are excluded (buying on
  // credit is not supported as a linked deduction).
  final fundSources = holdings
      .where((h) {
        final t = AssetType.fromStorage(h.assetType);
        return h.id != holding.id &&
            t != AssetType.liability &&
            (t.isAmountBased || h.quantity > 0);
      })
      .toList();

  // Available transaction types for this holding.
  final available = isShare
      ? <TransactionType>[
          TransactionType.buy,
          TransactionType.sell,
          TransactionType.dividend,
          TransactionType.split,
        ]
      : isLiability
          ? <TransactionType>[
              TransactionType.consume,
              TransactionType.transferIn, // 还款
              TransactionType.transferOut, // 借款
            ]
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
  final cashId = ValueNotifier<int?>(
    isShare
        ? (cashHoldings.isEmpty ? null : cashHoldings.first.id)
        : (moneyHoldings.isEmpty ? null : moneyHoldings.first.id),
  );
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
        t == TransactionType.transferOut ||
        t == TransactionType.consume ||
        t == TransactionType.split) {
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
    if (t == TransactionType.buy) {
      final id = cashId.value;
      if (id != null) {
        for (final h in holdings) {
          if (h.id != id) continue;
          final st = AssetType.fromStorage(h.assetType);
          if (st.isAmountBased) return null;
          if (h.currency != holding.currency) {
            return '资金来源与目标产品币种不一致';
          }
          final unit = h.latestPrice > 0
              ? h.latestPrice
              : (h.costPrice > 0 ? h.costPrice : 1.0);
          final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
          if (unit > 0 && h.quantity * unit + 1e-6 < amount) {
            return '资金来源「${h.name}」可用市值不足'
                '（可用 ${Formats.amount(h.quantity * unit)}）';
          }
          return null;
        }
      }
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
            if (isShare &&
                txnType.value != TransactionType.dividend &&
                txnType.value != TransactionType.split) ...[
              TerminalTextField(
                controller: qtyCtrl,
                label: '数量 / 份额 / 克数',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => syncAmount(qtyCtrl, priceCtrl, amountCtrl),
              ),
              const SizedBox(height: 12),
              TerminalTextField(
                controller: priceCtrl,
                label: '单价',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => syncAmount(qtyCtrl, priceCtrl, amountCtrl),
              ),
              const SizedBox(height: 12),
              TerminalTextField(
                controller: amountCtrl,
                label: '金额（自动 = 数量 × 单价，可改）',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              if (txnType.value == TransactionType.sell) ...[
                const SizedBox(height: 8),
                ValueListenableBuilder<TransactionType>(
                  valueListenable: txnType,
                  builder: (context, _, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '预计落袋收益：${sellProfitText(qtyCtrl, priceCtrl, holding)}',
                      style: T.label(size: 12, color: T.text2),
                    ),
                  ),
                ),
              ],
            ] else ...[
              ValueListenableBuilder<TransactionType>(
                valueListenable: txnType,
                builder: (context, t, _) => TerminalTextField(
                  controller: amountCtrl,
                  label: switch (t) {
                    TransactionType.dividend => '分红金额',
                    TransactionType.income => '收入金额',
                    TransactionType.expense => '支出金额',
                    TransactionType.transferIn => '转入金额',
                    TransactionType.transferOut => '转出金额',
                    TransactionType.consume => '消费金额',
                    TransactionType.split => '折算比例',
                    _ => '金额',
                  },
                  hint: t == TransactionType.split
                      ? '如 2 = 1 份拆成 2 份'
                      : null,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
            ],
            const SizedBox(height: 12),
            ValueListenableBuilder<TransactionType>(
              valueListenable: txnType,
              builder: (context, t, _) {
                final dropdownHoldings = isShare
                    ? (t == TransactionType.buy ? fundSources : cashHoldings)
                    : moneyHoldings;
                if (dropdownHoldings.isEmpty ||
                    t == TransactionType.consume ||
                    t == TransactionType.split) {
                  return const SizedBox.shrink();
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ValueListenableBuilder<int?>(
                      valueListenable: cashId,
                      builder: (context, value, _) => DropdownButtonFormField<int>(
                        initialValue: value,
                        decoration: terminalDecoration(counterpartyLabel(t, isShare)),
                        items: [
                          for (final c in dropdownHoldings)
                            DropdownMenuItem(
                              value: c.id,
                              child: Text(
                                _sourceItemLabel(c),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => cashId.value = v,
                      ),
                    ),
                    if (isShare)
                      ListenableBuilder(
                        listenable: Listenable.merge([cashId, amountCtrl]),
                        builder: (context, _) => Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              t == TransactionType.buy
                                  ? _buySourceHint(
                                      cashId.value, holdings, amountCtrl.text)
                                  : '不选则卖出回款不入账',
                              style: T.label(size: 12, color: T.text2),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            TerminalTextField(
              controller: noteCtrl,
              label: '备注（可选）',
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
            if (t == TransactionType.split && amount <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('折算比例必须大于 0')),
              );
              return;
            }
            final service = ref.read(transactionServiceProvider);
            final sourceId = cashId.value;
            HoldingRow? source;
            if (sourceId != null) {
              for (final h in holdings) {
                if (h.id == sourceId) {
                  source = h;
                  break;
                }
              }
            }
            final fundedByHolding = isShare &&
                t == TransactionType.buy &&
                source != null &&
                !AssetType.fromStorage(source.assetType).isAmountBased;
            final result = fundedByHolding
                ? await service.recordBuyFundedByHolding(
                    sourceHoldingId: source.id,
                    targetHoldingId: holding.id,
                    targetQuantity: qty ?? 0,
                    targetPrice: price,
                    amount: amount,
                    currency: holding.currency,
                    note: noteCtrl.text.trim(),
                  )
                : await service.record(
                    accountId: holding.accountId,
                    holdingId: (isShare || t == TransactionType.consume)
                        ? holding.id
                        : null,
                    type: t,
                    quantity: isShare &&
                            t != TransactionType.dividend &&
                            t != TransactionType.split
                        ? qty
                        : null,
                    price: isShare &&
                            t != TransactionType.dividend &&
                            t != TransactionType.split
                        ? price
                        : null,
                    amount: amount,
                    cashSourceId: switch (t) {
                      TransactionType.buy => cashId.value,
                      TransactionType.expense => holding.id,
                      TransactionType.transferIn => cashId.value,
                      TransactionType.transferOut => holding.id,
                      _ => null,
                    },
                    cashTargetId: switch (t) {
                      TransactionType.sell ||
                      TransactionType.dividend =>
                        cashId.value,
                      TransactionType.income => holding.id,
                      TransactionType.transferIn => holding.id,
                      TransactionType.transferOut => cashId.value,
                      _ => null,
                    },
                    note: noteCtrl.text.trim(),
                  );
            if (!context.mounted) return;
            Navigator.pop(context);
            if (result.ok) {
              ref.read(daoProvider).setSetting(historySyncDirtyKey, historyDirtySet);
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(result.ok ? '已记录' : (result.message ?? '记录失败')),
                backgroundColor: result.ok ? null : T.up,
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

/// Dropdown label for a funding source: cash shows its balance,
/// share-based holdings show their current market value.
String _sourceItemLabel(HoldingRow h) {
  final t = AssetType.fromStorage(h.assetType);
  final unit = h.latestPrice > 0 ? h.latestPrice : h.costPrice;
  final available = t.isAmountBased ? h.quantity : h.quantity * unit;
  return '${h.name} (${t.label}) · 可用 ${Formats.amount(available)}';
}

/// Hint under the buy funding-source dropdown: what will happen on save.
String _buySourceHint(
  int? sourceId,
  List<HoldingRow> holdings,
  String amountText,
) {
  if (sourceId == null) return '不选则不联动扣款';
  HoldingRow? source;
  for (final h in holdings) {
    if (h.id == sourceId) {
      source = h;
      break;
    }
  }
  if (source == null) return '不选则不联动扣款';
  final t = AssetType.fromStorage(source.assetType);
  if (t.isAmountBased) return '保存时从 ${source.name} 扣减该金额';
  final unit = source.latestPrice > 0
      ? source.latestPrice
      : (source.costPrice > 0 ? source.costPrice : 1.0);
  final amount = double.tryParse(amountText.trim()) ?? 0;
  if (amount <= 0 || unit <= 0) {
    return '保存时赎回 ${source.name} 对应份额用于本笔买入';
  }
  return '将赎回 ${source.name} 约 ${Formats.num(amount / unit)} 份'
      '（单价 ${Formats.smartNum(unit)}）用于本笔买入';
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
                          style: T.label(size: 12, color: T.text2),
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
            TerminalTextField(
              controller: amountCtrl,
              label: '金额',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            TerminalTextField(
              controller: noteCtrl,
              label: '备注（可选）',
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
            if (result.ok) {
              ref.read(daoProvider).setSetting(historySyncDirtyKey, historyDirtySet);
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(result.ok ? '已记录' : (result.message ?? '记录失败')),
                backgroundColor: result.ok ? null : T.up,
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
        decoration: terminalDecoration(label),
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
