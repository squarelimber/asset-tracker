import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../core/history_sync.dart';
import '../../data/database.dart';
import '../components/form_fields.dart';
import '../tokens.dart';

/// Caps an AlertDialog's total height so it always fits on screen (long
/// forms + keyboard): pass as `constraints:`. Title/actions stay visible,
/// the content scrolls in the remaining space.
BoxConstraints _dialogConstraints(BuildContext context) {
  final view = MediaQuery.viewInsetsOf(context);
  final available =
      MediaQuery.sizeOf(context).height - view.vertical - 48.0; // insetPadding ×2
  return BoxConstraints(maxHeight: available.clamp(240.0, double.infinity));
}

/// Dialog for recording a transaction against a specific holding.
/// Available types follow the holding's nature:
/// - share-based (stocks/funds/gold/wealth/crypto/bonds/futures/property):
///   buy / sell / dividend / split
/// - amount-based (cash/deposit/liquid wealth): income / expense /
///   transfer in / transfer out
Future<void> showHoldingTransactionDialog(
  BuildContext context,
  WidgetRef ref,
  HoldingRow holding,
) async {
  final hidden = ref.read(hideAmountsProvider);
  final holdings = ref.read(holdingsProvider).value ?? const [];
  final type = AssetType.fromStorage(holding.assetType);
  // Share-like holdings trade by quantity × unit price (stocks, funds,
  // gold, crypto, bank wealth, bonds, futures, property). Only amount-based
  // balances and liabilities use the income/expense form. (The old
  // market-linked || bankWealth check silently excluded the bond/futures
  // types added in v0.9.x, leaving them no working transaction path.)
  final isShare = !type.isAmountBased && type != AssetType.liability;
  final isLiability = type == AssetType.liability;
  const externalFunding = -1;

  // Money holdings usable as the counterparty for transfers. Same-currency
  // only: a cross-currency transfer would move the same number on both
  // sides without any conversion (corrupting the net worth).
  final moneyHoldings = holdings
      .where((h) {
        final t = AssetType.fromStorage(h.assetType);
        return !h.archived && (t.isAmountBased || t == AssetType.liability) &&
            h.currency == holding.currency &&
            h.id != holding.id;
      })
      .toList();

  // Cash holdings (amount-based only) usable as the sell/dividend credit
  // target for a share-based holding. Same-currency only (the service
  // asserts this as well).
  final cashHoldings = holdings
      .where((h) {
        final t = AssetType.fromStorage(h.assetType);
        return !h.archived && t.isAmountBased &&
            h.currency == holding.currency &&
            h.id != holding.id;
      })
      .toList();

  // Holdings usable as the funding source for a buy: cash holdings plus
  // share-based holdings with a positive balance (e.g. a money-market fund
  // redeemed to buy a new product). Liabilities are excluded (buying on
  // credit is not supported as a linked deduction), as are other currencies.
  final fundSources = holdings
      .where((h) {
        final t = AssetType.fromStorage(h.assetType);
        return !h.archived && h.id != holding.id &&
            t != AssetType.liability &&
            h.currency == holding.currency &&
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
  final cashId = ValueNotifier<int?>(null);
  int? linkedCashId() => cashId.value == externalFunding ? null : cashId.value;
  final noteCtrl = TextEditingController();
  // 发生日期：默认今天。补录历史操作（如 9 月初买入、今天才记账）时必须能
  // 改成真实发生日期，否则历史回放会把今天才发生的流水放在错误的日子，
  // 出现「钱在转账前已消失/还在」的错位（2026-09 月月鑫双计问题）。
  final occurredAt = ValueNotifier<DateTime>(DateTime.now());

  String? validate() {
    final t = txnType.value;
    if (isShare &&
        (t == TransactionType.buy || t == TransactionType.sell) &&
        cashId.value == null) {
      return t == TransactionType.buy ? '请选择扣款来源' : '请选择回款去向';
    }
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
      final id = linkedCashId();
      if (id != null) {
        for (final h in holdings) {
          if (h.id != id) continue;
          final st = AssetType.fromStorage(h.assetType);
          if (st.isAmountBased) {
            final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
            if (h.quantity + 1e-6 < amount) {
              return '资金来源「${h.name}」余额不足'
                  '（可用 ${hidden ? '****' : Formats.amount(h.quantity)}）';
            }
            return null;
          }
          if (h.currency != holding.currency) {
            return '资金来源与目标产品币种不一致';
          }
          // Per-unit price fallback (1.0) — a DIFFERENT rule from
          // effectiveCostOf(); mirrors transaction_service.dart.
          final unit = h.latestPrice > 0
              ? h.latestPrice
              : (h.costPrice > 0 ? h.costPrice : 1.0);
          final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
          if (unit > 0 && h.quantity * unit + 1e-6 < amount) {
            return '资金来源「${h.name}」可用市值不足'
                '（可用 ${hidden ? '****' : Formats.amount(h.quantity * unit)}）';
          }
          return null;
        }
      }
    }
    return null;
  }

  var saving = false;
  String? saveError;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => PopScope(
        canPop: !saving,
        child: AlertDialog(
          constraints: _dialogConstraints(context),
          title: Text('记一笔 · ${holding.name}'),
          content: AbsorbPointer(
            absorbing: saving,
            child: SingleChildScrollView(
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
                      onSelectionChanged: (s) => setState(() {
                        if (txnType.value != s.first) cashId.value = null;
                        txnType.value = s.first;
                      }),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (isShare &&
                      txnType.value != TransactionType.dividend &&
                      txnType.value != TransactionType.split) ...[
                    if (txnType.value == TransactionType.sell) ...[
                      ValueListenableBuilder<TransactionType>(
                        valueListenable: txnType,
                        builder: (context, t, _) => Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () {
                              // 全部卖出：数量 = 当前持仓，单价 = 最新价（无则成本价）。
                              // 省去赎回大额份额时手动查净值/份额的麻烦。
                              final unit = holding.latestPrice > 0
                                  ? holding.latestPrice
                                  : holding.costPrice;
                              // Keep the exact quantity so selling all leaves no fractional balance.
                              qtyCtrl.text = holding.quantity.toString();
                              priceCtrl.text = unit.toString();
                              syncAmount(qtyCtrl, priceCtrl, amountCtrl);
                            },
                            icon: const Icon(Icons.select_all, size: 18),
                            label: const Text('全部卖出'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
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
                            '预计落袋收益：${hidden ? '****' : sellProfitText(qtyCtrl, priceCtrl, holding)}',
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
                      // Counterparty picker: only transfer-type rows have a source
                      // / destination. Income / expense (and consume / split) are
                      // sourceless — the amount simply moves in or out of the
                      // holding itself — so no dropdown is shown for them.
                      final dropdownHoldings = isShare
                          ? (t == TransactionType.buy ? fundSources : cashHoldings)
                          : (t == TransactionType.transferIn ||
                                  t == TransactionType.transferOut
                              ? moneyHoldings
                              : <HoldingRow>[]);
                      final canUseExternal = isShare &&
                          (t == TransactionType.buy || t == TransactionType.sell);
                      final needsCounterparty = isShare
                          ? t != TransactionType.split
                          : t == TransactionType.transferIn || t == TransactionType.transferOut;
                      if (!needsCounterparty) return const SizedBox.shrink();
                      if (dropdownHoldings.isEmpty && !canUseExternal) {
                        return Text('暂无可用的同币种持仓', style: T.label(color: T.warning));
                      }
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ValueListenableBuilder<int?>(
                            valueListenable: cashId,
                            builder: (context, value, _) => DropdownButtonFormField<int>(
                              key: ValueKey(t),
                              initialValue: value,
                              decoration: terminalDecoration(counterpartyLabel(t, isShare)),
                              items: [
                                if (canUseExternal)
                                  DropdownMenuItem<int>(
                                    value: externalFunding,
                                    child: Text(t == TransactionType.buy
                                        ? '不扣应用内余额'
                                        : '回款不入账'),
                                  ),
                                for (final c in dropdownHoldings)
                                  DropdownMenuItem(
                                    value: c.id,
                                    child: Text(
                                      _sourceItemLabel(c, hidden),
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
                                            linkedCashId(), holdings, amountCtrl.text,
                                            external: cashId.value == externalFunding,
                                            hidden: hidden,
                                          )
                                        : t == TransactionType.sell && cashId.value == externalFunding
                                        ? '本次卖出仅减少产品份额，钱款不会进入应用内持仓。'
                                        : '',
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
                  _TransactionDateField(value: occurredAt),
                  const SizedBox(height: 12),
                  TerminalTextField(
                    controller: noteCtrl,
                    label: '备注（可选）',
                  ),
                  if (saveError != null) ...[
                    const SizedBox(height: 12),
                    Text(saveError!, style: T.label(color: T.up)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(
              onPressed: saving ? null : () async {
                final error = validate();
                if (error != null) {
                  setState(() => saveError = error);
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
                final sourceId = linkedCashId();
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
                // 补录历史日期的流水同样更新当前持仓并校验当前余额；
                // 日期用于后续历史回放。
                final when = occurredAt.value;
                final now = DateTime.now();
                final backdated =
                    when.year != now.year ||
                        when.month != now.month ||
                        when.day != now.day;
                setState(() {
                  saving = true;
                  saveError = null;
                });
                try {
                  final record = backdated ? service.recordHistorical : service.record;
                  final result = fundedByHolding
                      ? await service.recordBuyFundedByHolding(
                          sourceHoldingId: source.id,
                          targetHoldingId: holding.id,
                          targetQuantity: qty ?? 0,
                          targetPrice: price,
                          amount: amount,
                          currency: holding.currency,
                          occurredAt: when,
                          note: noteCtrl.text.trim(),
                        )
                      : await record(
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
                            TransactionType.buy => linkedCashId(),
                            TransactionType.transferIn => linkedCashId(),
                            TransactionType.transferOut => holding.id,
                            _ => null,
                          },
                          cashTargetId: switch (t) {
                            TransactionType.sell ||
                            TransactionType.dividend =>
                              linkedCashId(),
                            TransactionType.income ||
                            TransactionType.expense =>
                              holding.id,
                            TransactionType.transferIn => holding.id,
                            TransactionType.transferOut => linkedCashId(),
                            _ => null,
                          },
                          note: noteCtrl.text.trim(),
                          currency: holding.currency,
                          occurredAt: when,
                        );
                  if (!context.mounted) return;
                  if (!result.ok) {
                    setState(() {
                      saving = false;
                      saveError = _transactionError(result.message, hidden);
                    });
                    return;
                  }
                  final messenger = ScaffoldMessenger.of(context);
                  setState(() => saving = false);
                  Navigator.pop(context);
                  _markTransactionHistory(ref, backdated);
                  messenger.showSnackBar(const SnackBar(content: Text('已记录')));
                } catch (_) {
                  if (!context.mounted) return;
                  setState(() {
                    saving = false;
                    saveError = '记录失败，请重试';
                  });
                }
              },
              child: Text(saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ),
    ),
  );
  // Wait for the dialog's exit animation before releasing controllers,
  // mirroring showEditHoldingDialog: a rebuild during the animation would
  // otherwise touch a disposed controller and crash the close flow.
  await Future<void>.delayed(const Duration(milliseconds: 350));
  qtyCtrl.dispose();
  priceCtrl.dispose();
  amountCtrl.dispose();
  noteCtrl.dispose();
  occurredAt.dispose();
}

String _transactionError(String? message, bool hidden) {
  final text = message ?? '记录失败';
  return hidden ? text.replaceAll(RegExp(r'（可用 [^）]*）'), '（可用 ****）') : text;
}

void _markTransactionHistory(WidgetRef ref, bool backdated) {
  final dao = ref.read(daoProvider);
  unawaited(dao.transaction(() async {
    if (backdated) await dao.setSetting(historyFullRebuildKey, '1');
    await dao.setSetting(historySyncDirtyKey, historyDirtySet);
  }));
}

/// Date picker for the transaction's 发生日期 (defaults to today; change it
/// when backfilling an operation that happened earlier — otherwise the
/// history replay places the flow on the wrong day).
class _TransactionDateField extends StatelessWidget {
  const _TransactionDateField({required this.value});

  final ValueNotifier<DateTime> value;

  Future<void> _pick(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: value.value,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) value.value = picked;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: value,
      builder: (context, v, _) => InkWell(
        onTap: () => _pick(context),
        child: InputDecorator(
          decoration: terminalDecoration('发生日期'),
          child: Row(
            children: [
              const Icon(Icons.calendar_today_outlined, size: 16),
              const SizedBox(width: 8),
              Text(Formats.date(v)),
            ],
          ),
        ),
      ),
    );
  }
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
  return '${profit >= 0 ? '+' : ''}${Formats.money(profit, holding.currency)}';
}

/// Label of the counterparty dropdown for the current transaction type.
String counterpartyLabel(TransactionType t, bool isShare) {
  if (isShare) {
    return switch (t) {
      TransactionType.buy => '扣款来源',
      TransactionType.sell => '回款去向',
      _ => '入账现金持仓',
    };
  }
  return switch (t) {
    TransactionType.transferIn => '资金来源持仓',
    TransactionType.transferOut => '资金去向持仓',
    _ => '对方持仓',
  };
}

/// Dropdown label for a funding source: cash shows its balance,
/// share-based holdings show their current market value.
String _sourceItemLabel(HoldingRow h, bool hidden) {
  final t = AssetType.fromStorage(h.assetType);
  // Same fallback chain as the save-time deduction check
  // (transaction_service: latestPrice -> costPrice -> 1.0), so a share-based
  // holding with both prices at 0 cannot show "可用 0" while the save still
  // lets the whole balance move.
  final unit = h.latestPrice > 0
      ? h.latestPrice
      : (h.costPrice > 0 ? h.costPrice : 1.0);
  final available = t.isAmountBased ? h.quantity : h.quantity * unit;
  return '${h.name} (${t.label}) · 可用 ${hidden ? '****' : Formats.amount(available)}';
}

/// Hint under the buy funding-source dropdown: what will happen on save.
String _buySourceHint(
  int? sourceId,
  List<HoldingRow> holdings,
  String amountText, {
  required bool external,
  required bool hidden,
}) {
  if (external) return '本次买入只增加目标持仓。';
  final source = holdings.where((holding) => holding.id == sourceId).firstOrNull;
  if (source == null) return '请选择一项持仓扣款，或选择应用外资金。';
  final type = AssetType.fromStorage(source.assetType);
  final entered = double.tryParse(amountText.trim());
  final amount = entered != null && entered.isFinite ? entered : 0.0;
  if (type.isAmountBased) {
    if (amount <= 0 || hidden) return '保存时从 ${source.name} 扣款';
    return '从 ${source.name} 扣款 · 预计余额 ${Formats.money(source.quantity - amount, source.currency)}';
  }
  final unit = source.latestPrice > 0
      ? source.latestPrice
      : (source.costPrice > 0 ? source.costPrice : 1.0);
  if (amount <= 0 || hidden) return '保存时赎回 ${source.name} 用于本笔买入';
  final quantity = amount / unit;
  return '将赎回 ${source.name} 约 ${Formats.num(quantity)} 份 · 预计剩余 ${Formats.num(source.quantity - quantity)} 份';
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
  final List<HoldingRow> holdings;
  final List<AccountRow> accounts;
  try {
    holdings = await ref.read(holdingsProvider.future);
    accounts = await ref.read(accountsProvider.future);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('账户或持仓加载失败，请重试')),
      );
    }
    return;
  }
  if (!context.mounted) return;
  final moneyHoldings = holdings
      .where((h) {
        final t = AssetType.fromStorage(h.assetType);
        return !h.archived && (t.isAmountBased || t == AssetType.liability);
      })
      .toList();
  final accountHoldings =
      moneyHoldings.where((h) => h.accountId == accountId).toList();
  final accountNames = {for (final account in accounts) account.id: account.name};
  if (accountHoldings.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('请先为当前账户添加现金、存款或负债持仓')),
    );
    return;
  }

  final hidden = ref.read(hideAmountsProvider);
  final txnType = ValueNotifier<TransactionType>(TransactionType.transferOut);
  final sourceId = ValueNotifier<int?>(accountHoldings.first.id);
  final targetId = ValueNotifier<int?>(null);
  final amountCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  final occurredAt = ValueNotifier<DateTime>(DateTime.now());

  var saving = false;
  String? saveError;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => PopScope(
        canPop: !saving,
        child: AlertDialog(
          constraints: _dialogConstraints(context),
          title: const Text('记流水'),
          content: AbsorbPointer(
            absorbing: saving,
            child: SingleChildScrollView(
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
                              holdings: accountHoldings,
                              accountNames: accountNames,
                              value: sourceId,
                            ),
                            const SizedBox(height: 12),
                            MoneyDropdown(
                              label: '资金去向（现金转入 / 负债还款）',
                              holdings: moneyHoldings,
                              accountNames: accountNames,
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
                        holdings: accountHoldings,
                        accountNames: accountNames,
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
                  _TransactionDateField(value: occurredAt),
                  const SizedBox(height: 12),
                  TerminalTextField(
                    controller: noteCtrl,
                    label: '备注（可选）',
                  ),
                  if (saveError != null) ...[
                    const SizedBox(height: 12),
                    Text(saveError!, style: T.label(color: T.up)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(
              onPressed: saving ? null : () async {
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
                if (txnTypeValue == TransactionType.transferOut &&
                    sourceId.value == targetId.value) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('资金来源和去向不能相同')),
                  );
                  return;
                }
                // Upfront transfer checks (mirrors the service assertions so the
                // user gets a precise message before anything is written):
                // same-currency only, and a cash source cannot be overdrawn.
                if (txnTypeValue == TransactionType.transferOut) {
                  HoldingRow? src;
                  HoldingRow? tgt;
                  for (final h in holdings) {
                    if (h.id == sourceId.value) src = h;
                    if (h.id == targetId.value) tgt = h;
                  }
                  if (src != null && tgt != null && src.currency != tgt.currency) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                            '转账币种不一致：「${src.name}」(${src.currency}) 与「${tgt.name}」(${tgt.currency})'),
                        backgroundColor: T.up,
                      ));
                    }
                    return;
                  }
                  if (src != null) {
                    final st = AssetType.fromStorage(src.assetType);
                    if (st.isAmountBased && src.quantity + 1e-6 < amount) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('「${src.name}」余额不足'
                              '（可用 ${hidden ? '****' : Formats.amount(src.quantity)}）'),
                          backgroundColor: T.up,
                        ));
                      }
                      return;
                    }
                  }
                }
                // Record the flow in the source holding's currency so foreign
                // income/expense rows no longer enter the stats as CNY amounts.
                HoldingRow? srcHolding;
                for (final h in holdings) {
                  if (h.id == sourceId.value) {
                    srcHolding = h;
                    break;
                  }
                }
                setState(() {
                  saving = true;
                  saveError = null;
                });
                try {
                  final when = occurredAt.value;
                  final backdated = todayKey(when) != todayKey();
                  final service = ref.read(transactionServiceProvider);
                  final record = backdated ? service.recordHistorical : service.record;
                  final result = await record(
                    accountId: accountId,
                    occurredAt: when,
                    type: txnTypeValue,
                    amount: amount,
                    cashSourceId:
                        txnTypeValue == TransactionType.transferOut ? sourceId.value : null,
                    cashTargetId: txnTypeValue == TransactionType.transferOut
                        ? targetId.value
                        : sourceId.value,
                    note: noteCtrl.text.trim(),
                    currency: srcHolding?.currency ?? 'CNY',
                  );
                  if (!context.mounted) return;
                  if (!result.ok) {
                    setState(() {
                      saving = false;
                      saveError = _transactionError(result.message, hidden);
                    });
                    return;
                  }
                  final messenger = ScaffoldMessenger.of(context);
                  setState(() => saving = false);
                  Navigator.pop(context);
                  _markTransactionHistory(ref, backdated);
                  messenger.showSnackBar(const SnackBar(content: Text('已记录')));
                } catch (_) {
                  if (!context.mounted) return;
                  setState(() {
                    saving = false;
                    saveError = '记录失败，请重试';
                  });
                }
              },
              child: Text(saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ),
    ),
  );
  // Same exit-animation guard as above (see showHoldingTransactionDialog).
  await Future<void>.delayed(const Duration(milliseconds: 350));
  amountCtrl.dispose();
  noteCtrl.dispose();
  txnType.dispose();
  sourceId.dispose();
  targetId.dispose();
  occurredAt.dispose();
}

class MoneyDropdown extends StatelessWidget {
  const MoneyDropdown({
    super.key,
    required this.label,
    required this.holdings,
    required this.value,
    required this.accountNames,
  });

  final String label;
  final List<HoldingRow> holdings;
  final ValueNotifier<int?> value;
  final Map<int, String> accountNames;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int?>(
      valueListenable: value,
      builder: (context, current, _) => DropdownButtonFormField<int>(
        initialValue: current,
        decoration: terminalDecoration(label).copyWith(hintText: '请选择'),
        items: [
          for (final h in holdings)
            DropdownMenuItem(
              value: h.id,
              child: Text(
                '${accountNames[h.accountId] ?? '账户 #${h.accountId}'} · '
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
