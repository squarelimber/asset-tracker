import 'package:drift/drift.dart' hide Column, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/history_sync.dart';
import '../../../core/symbols.dart';
import '../../../data/database.dart';
import '../../components/form_fields.dart';
import '../../tokens.dart';
import 'invested_profit_field.dart';
import 'purchase_date_field.dart';

/// The cost_fx_rate companion value for the edit dialog: the parsed rate
/// when the currency is foreign, absent otherwise.
Value<double?> _editFxRateValue(
  TextEditingController fxRateCtrl,
  TextEditingController currencyCtrl,
  bool autoCny,
  HoldingRow holding,
) {
  final ccy = autoCny ? 'CNY' : currencyCtrl.text.trim().toUpperCase();
  if (ccy.isEmpty || ccy == 'CNY') return const Value<double?>.absent();
  final fx = double.tryParse(fxRateCtrl.text.trim());
  if (fx != null && fx > 0) return Value<double?>(fx);
  return const Value<double?>.absent();
}

Future<void> showAddHoldingDialog(BuildContext context, WidgetRef ref) async {
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

  // Current FX rates for pre-filling the purchase-rate field.
  final fxRates = await ref.read(cnyRatesProvider.future);

  final accountId = ValueNotifier<int?>(accounts.first.id);
  final assetType = ValueNotifier<AssetType>(AssetType.stock);
  final riskLevel = ValueNotifier<String?>(null);
  final nameCtrl = TextEditingController();
  final symbolCtrl = TextEditingController();
  final quantityCtrl = TextEditingController();
  final costPriceCtrl = TextEditingController();
  final latestPriceCtrl = TextEditingController();
  final currencyCtrl = TextEditingController(text: 'CNY');
  final fxRateCtrl = TextEditingController();
  final purchaseDate = ValueNotifier<DateTime?>(DateTime.now());
  final amount = ValueNotifier<double>(0);
  double? investedResult;

  if (!context.mounted) return;
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
                decoration: terminalDecoration('所属账户'),
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
                decoration: terminalDecoration('资产类型'),
                items: [
                  for (final t in AssetType.values)
                    DropdownMenuItem(value: t, child: Text(t.label)),
                ],
                onChanged: (v) => assetType.value = v ?? AssetType.stock,
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<AssetType>(
              valueListenable: assetType,
              builder: (context, value, _) => DropdownButtonFormField<String>(
                initialValue: 'auto',
                decoration: terminalDecoration('风险等级'),
                items: [
                  const DropdownMenuItem(
                    value: 'auto',
                    child: Text('自动（按资产类型）'),
                  ),
                  for (final r in RiskLevel.values)
                    DropdownMenuItem(
                      value: r.storageName,
                      child: Text(r.label),
                    ),
                ],
                onChanged: (v) => riskLevel.value = v == 'auto' ? null : v,
              ),
            ),
            const SizedBox(height: 12),
            TerminalTextField(controller: nameCtrl, label: '名称'),
            const SizedBox(height: 12),
            ValueListenableBuilder<AssetType>(
              valueListenable: assetType,
              builder: (context, type, _) {
                if (type.isAmountBased || type == AssetType.liability) {
                  // Amount-based assets (and liabilities) track a plain
                  // balance; liabilities get a tailored label and no
                  // invested/profit linkage.
                  final isLiability = type == AssetType.liability;
                  return Column(
                    children: [
                      TerminalTextField(
                        controller: quantityCtrl,
                        label: isLiability ? '当前欠款金额' : '当前金额',
                        hint: isLiability ? '如 3000' : '如 50000',
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (v) {
                          amount.value = double.tryParse(v.trim()) ?? 0;
                        },
                      ),
                      if (type.isAmountBased) ...[
                        const SizedBox(height: 12),
                        InvestedProfitField(
                          amount: amount,
                          initialInvested: null,
                          onChanged: (v) => investedResult = v,
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  );
                }
                final symbolEnabled =
                    type.isMarketLinked || type == AssetType.bankWealth;
                return Column(
                  children: [
                    TerminalTextField(
                      controller: symbolCtrl,
                      label: symbolEnabled ? '行情代码' : '（手动净值资产无需代码）',
                      hint: switch (type) {
                        AssetType.stock || AssetType.etf =>
                          '如 510880 / 159915（自动识别沪/深）',
                        AssetType.mutualFund => '如 110022',
                        AssetType.gold => 'AU99.99（自动金价）',
                        AssetType.crypto => '如 bitcoin',
                        AssetType.bankWealth =>
                          '填外汇代码如 USD 可自动汇率联动，留空手动净值',
                        _ => null,
                      },
                      enabled: symbolEnabled,
                    ),
                    const SizedBox(height: 12),
                    TerminalTextField(
                      controller: quantityCtrl,
                      label: '数量 / 份额 / 克数',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TerminalTextField(
                      controller: costPriceCtrl,
                      label: '成本单价',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TerminalTextField(
                      controller: latestPriceCtrl,
                      label: '最新净值（可选）',
                      hint: type.isMarketLinked
                          ? '留空则保存后自动获取'
                          : '手动净值资产建议填写',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                );
              },
            ),
            ValueListenableBuilder<AssetType>(
              valueListenable: assetType,
              builder: (context, type, _) => PurchaseDateField(
                value: purchaseDate,
                label: type == AssetType.liability ? '开卡日期' : '买入日期',
                daysLabel: type == AssetType.liability
                    ? '开卡天数（选填，与日期二选一）'
                    : '持有天数（选填，与日期二选一）',
                daysHint: type == AssetType.liability
                    ? '如 400 = 400 天前开卡'
                    : '如 400 = 400 天前买入',
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<AssetType>(
              valueListenable: assetType,
              builder: (context, type, _) {
                final autoCny = type.isMarketLinked ||
                    type == AssetType.bankWealth;
                if (autoCny) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '币种：人民币（行情自动折算）',
                      style: T.label(size: 13, color: T.text2),
                    ),
                  );
                }
                return Column(
                  children: [
                    TerminalTextField(
                      controller: currencyCtrl,
                      label: '币种 (ISO 代码)',
                      onChanged: (v) {
                        // Pre-fill the purchase rate with the current
                        // rate for the chosen currency.
                        final ccy = v.trim().toUpperCase();
                        final rate = fxRates[ccy];
                        fxRateCtrl.text = (rate == null || rate <= 0)
                            ? ''
                            : rate.toString();
                      },
                    ),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: currencyCtrl,
                      builder: (context, value, _) {
                        final ccy = value.text.trim().toUpperCase();
                        if (ccy.isEmpty || ccy == 'CNY') {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: TerminalTextField(
                            controller: fxRateCtrl,
                            label: '买入时汇率（$ccy/CNY）',
                            hint: '默认已填当前汇率，可改为真实买入汇率',
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () async {
            final name = nameCtrl.text.trim();
            final type = assetType.value;
            final qty = double.tryParse(quantityCtrl.text.trim());
            final invested = double.tryParse(costPriceCtrl.text.trim());
            final isAmount = type.isAmountBased || type == AssetType.liability;
            final costRequired = isAmount ? 1 : 2;
            if (name.isEmpty || qty == null || (costRequired == 2 && invested == null)) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(isAmount
                      ? '请填写名称和当前金额'
                      : '请填写名称、数量、成本单价'),
                ),
              );
              return;
            }
            final dao = ref.read(daoProvider);
            var symbol = symbolCtrl.text.trim().isNotEmpty
                ? symbolCtrl.text.trim()
                : type.defaultSymbol;
            // Auto-prefix bare 6-digit A-share/ETF codes (5/6 -> sh, 0/1/3 -> sz).
            if (type == AssetType.stock || type == AssetType.etf) {
              symbol = symbol == null ? null : normalizeSinaSymbol(symbol);
            }
            final hasSymbol = symbol != null && symbol.isNotEmpty;
            final marketSource = switch (type) {
              AssetType.stock || AssetType.etf => 'sina',
              AssetType.mutualFund => 'eastmoney',
              AssetType.gold => 'sge',
              AssetType.crypto => 'coingecko',
              AssetType.bankWealth when hasSymbol => 'forex',
              _ => 'manual',
            };
            final userPrice = double.tryParse(latestPriceCtrl.text.trim());
            final autoCny =
                type.isMarketLinked || type == AssetType.bankWealth;
            int createdId;
            try {
              final finalCurrency = autoCny
                  ? 'CNY'
                  : (currencyCtrl.text.trim().toUpperCase().isEmpty
                      ? 'CNY'
                      : currencyCtrl.text.trim().toUpperCase());
              final fx = double.tryParse(fxRateCtrl.text.trim());
              createdId = await dao.createHolding(HoldingsCompanion.insert(
                accountId: accountId.value!,
                name: name,
                assetType: type.storageName,
                marketSource: Value(marketSource),
                symbol: hasSymbol ? Value(symbol) : const Value.absent(),
                quantity: Value(qty),
                costPrice: Value(isAmount
                    ? (type.isAmountBased
                        ? (investedResult ?? qty)
                        : 1) // liability: unit price 1, cost = balance
                    : (invested ?? 0)),
                latestPrice: Value(isAmount ? 1 : (userPrice ?? 0)),
                costFxRate: finalCurrency != 'CNY' && fx != null && fx > 0
                    ? Value(fx)
                    : const Value.absent(),
                purchaseDate: Value(purchaseDate.value),
                riskLevel: riskLevel.value == null
                    ? const Value.absent()
                    : Value(riskLevel.value),
                currency: Value(finalCurrency),
              ));
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('保存失败：$e')),
                );
              }
              return;
            }
            if (context.mounted) Navigator.pop(context);

            // Auto-fetch the latest price for market-linked holdings
            // unless the user already entered one.
            if (marketSource != 'manual' && hasSymbol) {
              final created = await dao.getHolding(createdId);
              if (created != null) {
                final quote =
                    await ref.read(marketServiceProvider).refreshHolding(created);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  quote != null
                      ? SnackBar(
                          content: Text(
                              '已自动获取最新净值：${Formats.smartNum(quote.price)}'),
                        )
                      : const SnackBar(
                          content: Text('自动获取净值失败：请检查行情代码，'
                              '或稍后在持仓页点 ⚡ 刷新'),
                        ),
                );
              }
            }
            // Mark history sync dirty; the portfolio page rebuilds the
            // snapshots when opened next.
            ref.read(daoProvider).setSetting(historySyncDirtyKey, historyDirtySet);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  // Wait for the dialog's exit animation to finish before releasing the
  // controllers: otherwise a rebuild during the animation accesses an
  // already-disposed controller (crashes the save flow).
  await Future<void>.delayed(const Duration(milliseconds: 350));
  nameCtrl.dispose();
  symbolCtrl.dispose();
  quantityCtrl.dispose();
  costPriceCtrl.dispose();
  latestPriceCtrl.dispose();
  currencyCtrl.dispose();
  fxRateCtrl.dispose();
}

Future<void> showUpdatePriceDialog(
  BuildContext context,
  WidgetRef ref,
  HoldingRow holding,
) async {
  final priceCtrl = TextEditingController(
    text: holding.latestPrice > 0 ? holding.latestPrice.toString() : '',
  );
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('更新单价'),
      content: TerminalTextField(
        controller: priceCtrl,
        label: '最新单价',
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        autofocus: true,
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

Future<void> showEditHoldingDialog(
  BuildContext context,
  WidgetRef ref,
  HoldingRow holding,
) async {
  final accounts = await ref.read(accountsProvider.future);
  if (!context.mounted) return;
  // Current FX rates for pre-filling the purchase-rate field.
  final fxRates = await ref.read(cnyRatesProvider.future);
  if (!context.mounted) return;
  final initialType = AssetType.fromStorage(holding.assetType);
  final typeNotifier = ValueNotifier<AssetType>(initialType);
  final accountIdNotifier = ValueNotifier<int>(holding.accountId);
  final riskLevelNotifier = ValueNotifier<String?>(holding.riskLevel);
  final nameCtrl = TextEditingController(text: holding.name);
  final symbolCtrl = TextEditingController(text: holding.symbol ?? '');
  final quantityCtrl =
      TextEditingController(text: holding.quantity.toString());
  final costCtrl = TextEditingController(text: holding.costPrice.toString());
  final priceCtrl =
      TextEditingController(text: holding.latestPrice.toString());
  final currencyCtrl = TextEditingController(text: holding.currency);
  final fxRateCtrl = TextEditingController(
    text: holding.costFxRate == null
        ? ''
        : holding.costFxRate!.toString(),
  );
  final noteCtrl = TextEditingController(text: holding.note ?? '');
  final purchaseDate = ValueNotifier<DateTime?>(
    holding.purchaseDate ?? holding.createdAt,
  );
  final amount = ValueNotifier<double>(holding.quantity);
  double? investedResult = initialType.isAmountBased ? holding.costPrice : null;

  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final type = typeNotifier.value;
        final isAmountBased = type.isAmountBased;
        final isAmount = isAmountBased || type == AssetType.liability;
        final isLiability = type == AssetType.liability;
        final autoCny = type.isMarketLinked || type == AssetType.bankWealth;
        return AlertDialog(
          title: const Text('编辑持仓'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TerminalTextField(controller: nameCtrl, label: '名称'),
                const SizedBox(height: 12),
                ValueListenableBuilder<int>(
                  valueListenable: accountIdNotifier,
                  builder: (context, accountId, _) =>
                      DropdownButtonFormField<int>(
                    initialValue: accountId,
                    decoration: terminalDecoration('所属账户'),
                    items: [
                      for (final a in accounts)
                        DropdownMenuItem(value: a.id, child: Text(a.name)),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => accountIdNotifier.value = v);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<AssetType>(
                  initialValue: type,
                  decoration: terminalDecoration('资产类型'),
                  items: [
                    for (final t in AssetType.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => typeNotifier.value = v);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: holding.riskLevel ?? 'auto',
                  decoration: terminalDecoration('风险等级'),
                  items: [
                    const DropdownMenuItem(
                      value: 'auto',
                      child: Text('自动（按资产类型）'),
                    ),
                    for (final r in RiskLevel.values)
                      DropdownMenuItem(
                        value: r.storageName,
                        child: Text(r.label),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    riskLevelNotifier.value = v == 'auto' ? null : v;
                  }),
                ),
                if (!isAmount) ...[
                  const SizedBox(height: 12),
                  TerminalTextField(
                    controller: symbolCtrl,
                    label: '行情代码',
                    hint: '如 sh600519 / 110022 / AU99.99 / USD',
                  ),
                ],
                const SizedBox(height: 12),
                TerminalTextField(
                  controller: quantityCtrl,
                  label: isLiability
                      ? '当前欠款金额'
                      : (isAmount ? '当前金额' : '数量 / 份额 / 克数'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) {
                    if (isAmount) {
                      amount.value = double.tryParse(v.trim()) ?? 0;
                    }
                  },
                ),
                if (isAmountBased) ...[
                  const SizedBox(height: 12),
                  InvestedProfitField(
                    amount: amount,
                    initialInvested: holding.costPrice > 0 ? holding.costPrice : null,
                    onChanged: (v) => investedResult = v,
                  ),
                ] else if (!isLiability) ...[
                  const SizedBox(height: 12),
                  TerminalTextField(
                    controller: costCtrl,
                    label: '成本单价',
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                  const SizedBox(height: 12),
                  TerminalTextField(
                    controller: priceCtrl,
                    label: '最新单价',
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ],
                const SizedBox(height: 12),
                PurchaseDateField(
                  value: purchaseDate,
                  label: type == AssetType.liability ? '开卡日期' : '买入日期',
                  daysLabel: type == AssetType.liability
                      ? '开卡天数（选填，与日期二选一）'
                      : '持有天数（选填，与日期二选一）',
                  daysHint: type == AssetType.liability
                      ? '如 400 = 400 天前开卡'
                      : '如 400 = 400 天前买入',
                ),
                const SizedBox(height: 12),
                if (autoCny)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '币种：人民币（行情自动折算）',
                      style: T.label(size: 13, color: T.text2),
                    ),
                  )
                else
                  Column(
                    children: [
                      TerminalTextField(
                        controller: currencyCtrl,
                        label: '币种 (ISO 代码)',
                        onChanged: (v) {
                          final ccy = v.trim().toUpperCase();
                          final rate = fxRates[ccy];
                          fxRateCtrl.text = (rate == null || rate <= 0)
                              ? ''
                              : rate.toString();
                        },
                      ),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: currencyCtrl,
                        builder: (context, value, _) {
                          final ccy = value.text.trim().toUpperCase();
                          if (ccy.isEmpty || ccy == 'CNY') {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: TerminalTextField(
                              controller: fxRateCtrl,
                              label: '买入时汇率（$ccy/CNY）',
                              hint: '默认已填当前汇率，可改为真实买入汇率',
                              keyboardType: const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                TerminalTextField(controller: noteCtrl, label: '备注'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    ),
  );

  if (ok == true) {
    final type = typeNotifier.value;
    final isAmountBased = type.isAmountBased;
    final isAmount = isAmountBased || type == AssetType.liability;
    final autoCny = type.isMarketLinked || type == AssetType.bankWealth;
    final qty = double.tryParse(quantityCtrl.text.trim());
    if (qty == null) return;
    final cost = double.tryParse(costCtrl.text.trim());
    final price = double.tryParse(priceCtrl.text.trim());
    if (!isAmount && (cost == null || price == null)) return;
    final symbol = symbolCtrl.text.trim();
    // Market source follows the new asset type; amount-based assets are
    // manual by nature. A symbol change on a share holding with an empty
    // source also re-derives the source.
    final marketSource = isAmount
        ? 'manual'
        : MarketSource.fromStorage(holding.marketSource) == MarketSource.manual
            ? switch (type) {
                AssetType.stock || AssetType.etf => 'sina',
                AssetType.mutualFund => 'eastmoney',
                AssetType.gold => 'sge',
                AssetType.crypto => 'coingecko',
                AssetType.bankWealth => 'forex',
                _ => holding.marketSource,
              }
            : switch (type) {
                AssetType.stock || AssetType.etf => 'sina',
                AssetType.mutualFund => 'eastmoney',
                AssetType.gold => 'sge',
                AssetType.crypto => 'coingecko',
                AssetType.bankWealth =>
                  symbol.isNotEmpty ? 'forex' : 'manual',
                AssetType.cash ||
                AssetType.bankDeposit ||
                AssetType.liquidWealth ||
                AssetType.liability ||
                AssetType.property =>
                  'manual',
              };
    final updated = holding.copyWith(
      accountId: accountIdNotifier.value,
      name: nameCtrl.text.trim().isEmpty ? holding.name : nameCtrl.text.trim(),
      assetType: type.storageName,
      marketSource: marketSource,
      quantity: qty,
      costPrice: isAmount
          ? (isAmountBased ? (investedResult ?? qty) : 1) // liability: cost = balance
          : (cost ?? holding.costPrice),
      latestPrice: isAmount ? 1 : (price ?? holding.latestPrice),
      purchaseDate: Value(purchaseDate.value),
      riskLevel: riskLevelNotifier.value == null
          ? const Value.absent()
          : Value(riskLevelNotifier.value),
      symbol: !isAmount ? (symbol.isEmpty ? const Value.absent() : Value(symbol)) : const Value.absent(),
      currency: autoCny
          ? 'CNY'
          : (currencyCtrl.text.trim().toUpperCase().isEmpty
              ? holding.currency
              : currencyCtrl.text.trim().toUpperCase()),
      costFxRate: _editFxRateValue(fxRateCtrl, currencyCtrl, autoCny, holding),
      note: noteCtrl.text.trim().isEmpty ? const Value.absent() : Value(noteCtrl.text.trim()),
    );
    await ref.read(daoProvider).updateHolding(updated);
    ref.read(daoProvider).setSetting(historySyncDirtyKey, historyDirtySet);
  }
  // Wait for the dialog's exit animation before releasing controllers.
  await Future<void>.delayed(const Duration(milliseconds: 350));
  nameCtrl.dispose();
  symbolCtrl.dispose();
  quantityCtrl.dispose();
  costCtrl.dispose();
  priceCtrl.dispose();
  currencyCtrl.dispose();
  fxRateCtrl.dispose();
  noteCtrl.dispose();
}

Future<void> confirmDeleteHolding(
  BuildContext context,
  WidgetRef ref,
  HoldingRow holding,
) async {
  final hasTxns = (await ref.read(daoProvider).getTransactionsForHolding(holding.id)).isNotEmpty;
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除持仓'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('确定删除「${holding.name}」吗？相关交易流水也会被删除。'),
          if (hasTxns) ...[
            const SizedBox(height: 12),
            Text(
              '⚠️ 收益日历中该产品的历史收益将永久删除。'
              '如需保留历史，可改用「归档」。',
              style: const TextStyle(color: T.warning, fontSize: 12.5),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.up),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok == true) {
    await ref.read(daoProvider).deleteHolding(holding.id);
    ref.read(daoProvider).setSetting(historySyncDirtyKey, historyDirtySet);
  }
}
