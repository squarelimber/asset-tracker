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

/// Label for a funding-source option: available balance / market value.
String _fundingSourceLabel(HoldingRow h) {
  final t = AssetType.fromStorage(h.assetType);
  final unit = h.latestPrice > 0 ? h.latestPrice : h.costPrice;
  final available = t.isAmountBased ? h.quantity : h.quantity * unit;
  return '${h.name} (${t.label}) · 可用 ${Formats.amount(available)}';
}

/// Asset types offered for one category in the add-holding picker. The two
/// fund types collapse into a single "基金" entry (resolved to 场内/场外 by
/// the symbol at save time). [AssetType.liability] is a special entry
/// outside the plan categories.
///
/// 「基金」is appended to every category that can be held through a fund,
/// because a fund's *product* type and its *exposure* are different things:
/// a 黄金ETF / 豆粕ETF is an 场内基金 (share-based, quoted by Sina) whose
/// exposure is 黄金 / 商品. Picking the category here sets the exposure and
/// typing a 6-digit code makes the product an ETF — without this entry the
/// category could only be picked by mislabelling the product as 期货.
/// Categories where a fund makes no sense (现金/房产/银行理财) stay as-is.
List<AssetType> _typesOfCategory(AssetCategory category) {
  switch (category) {
    case AssetCategory.bond:
      return const [AssetType.bond, AssetType.mutualFund];
    case AssetCategory.equity:
      return const [AssetType.stock, AssetType.mutualFund];
    case AssetCategory.gold:
      return const [AssetType.gold, AssetType.mutualFund];
    case AssetCategory.commodity:
      return const [AssetType.crypto, AssetType.futures, AssetType.mutualFund];
    case AssetCategory.cash:
      return const [
        AssetType.cash,
        AssetType.bankDeposit,
        AssetType.liquidWealth,
      ];
    case AssetCategory.property:
      return const [AssetType.property];
    case AssetCategory.bankWealth:
      return const [AssetType.bankWealth];
  }
}

/// Picker label for an asset type in the add dialog; 场内基金/场外基金 merge
/// into a single "基金" entry so the type list stays short.
String _typePickerLabel(AssetType t) =>
    (t == AssetType.etf || t == AssetType.mutualFund) ? '基金' : t.label;

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
  // Manual allocation-category override; null = follow the asset type.
  final categoryOverride = ValueNotifier<AssetCategory?>(null);
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

  // Existing holdings usable as the funding source for this new one
  // (e.g. redeem a money-market fund to buy a new product). Liabilities
  // are excluded; share-based holdings need a positive balance.
  final holdings = ref.read(holdingsProvider).value ?? const [];
  final fundSources = holdings
      .where((h) {
        final t = AssetType.fromStorage(h.assetType);
        return t != AssetType.liability &&
            (t.isAmountBased || h.quantity > 0);
      })
      .toList();
  final fundingSourceId = ValueNotifier<int?>(null);

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
            ListenableBuilder(
              listenable: Listenable.merge([assetType, categoryOverride]),
              builder: (context, _) {
                final value = assetType.value;
                // The picked category is the *allocation* category (品类 =
                // 标的归类), while 具体类型 says how the holding is recorded
                // and priced. They only differ for a fund tracking something
                // other than equities — a 豆粕ETF is 商品 exposure held as an
                // 场内基金 — which is exactly what the override records.
                final category = categoryOverride.value ?? value.category;
                final candidates = _typesOfCategory(category);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Category first, then the specific type, so the picker
                    // stays short (7 categories + 负债 special entry).
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final c in AssetCategory.values)
                          ChoiceChip(
                            label: Text(c.label),
                            selected: value != AssetType.liability &&
                                category == c,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) {
                              categoryOverride.value = c;
                              // Keep the selected type when the new category
                              // still offers it, otherwise fall back to the
                              // category's default.
                              final next = _typesOfCategory(c);
                              if (!next.contains(assetType.value)) {
                                assetType.value = next.first;
                              }
                            },
                          ),
                        ChoiceChip(
                          label: const Text('负债'),
                          selected: value == AssetType.liability,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) {
                            categoryOverride.value = null;
                            assetType.value = AssetType.liability;
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (value == AssetType.liability)
                      const Text(
                        '负债持仓：信用卡、贷款等欠款（净资产中扣除）',
                        style: TextStyle(fontSize: 12.5, color: T.text2),
                      )
                    else ...[
                      DropdownButtonFormField<AssetType>(
                        initialValue: candidates.contains(value)
                            ? value
                            : candidates.first,
                        decoration: terminalDecoration('具体类型'),
                        items: [
                          for (final t in candidates)
                            DropdownMenuItem(
                              value: t,
                              child: Text(_typePickerLabel(t)),
                            ),
                        ],
                        onChanged: (v) => assetType.value = v ?? value,
                      ),
                      if (category != value.category)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '归类为「${category.label}」，产品类型为'
                            '「${_typePickerLabel(value)}」——资产配置、'
                            '配置比例告警与品类筛选都按「${category.label}」统计。',
                            style: const TextStyle(fontSize: 12, color: T.text2),
                          ),
                        ),
                    ],
                  ],
                );
              },
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
                    !type.isAmountBased && type != AssetType.liability;
                return Column(
                  children: [
                    TerminalTextField(
                      controller: symbolCtrl,
                      label: symbolEnabled ? '行情代码' : '（手动净值资产无需代码）',
                      hint: switch (type) {
                        AssetType.stock || AssetType.etf =>
                          '如 510880 / 159915（自动识别沪/深）',
                        AssetType.mutualFund =>
                          '如 110022；场内 6 位代码自动改为实时行情',
                        AssetType.gold => 'AU99.99（自动金价）',
                        AssetType.crypto => '如 bitcoin',
                        AssetType.futures =>
                          '选填：合约或产品代码（无实时行情，按手动净值）',
                        AssetType.bond =>
                          '选填：如 019742（国债）或基金代码，留空按手动净值',
                        AssetType.bankWealth =>
                          '填外汇代码如 USD 可自动汇率联动，留空手动净值',
                        _ => '选填：仅作记录，按手动净值',
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
            // Forex-linked bank wealth embeds the live rate in its unit
            // price (市值=数量×汇率), so the currency field is a free label
            // — always editable, never silently rewritten on save.
            ListenableBuilder(
              listenable: Listenable.merge([assetType, symbolCtrl]),
              builder: (context, _) {
                final forexLinked = assetType.value == AssetType.bankWealth &&
                    isFxCurrencyCode(symbolCtrl.text);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TerminalTextField(
                      controller: currencyCtrl,
                      label: forexLinked
                          ? '币种 (ISO 代码) · 汇率联动'
                          : '币种 (ISO 代码)',
                      hint: forexLinked
                          ? '单价将随汇率自动更新（单价=汇率）；币种为标记，市值=数量×汇率'
                          : '默认人民币 CNY；外币请填 ISO 代码（如 USD），市值将按汇率折算',
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
                            hint: (fxRates[ccy] == null || (fxRates[ccy] ?? 0) <= 0)
                                ? '该币种暂无自动汇率，市值将按 1:1 折算；请填写买入时汇率'
                                : '默认已填当前汇率，可改为真实买入汇率',
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
            ValueListenableBuilder<AssetType>(
              valueListenable: assetType,
              builder: (context, type, _) {
                if (type == AssetType.liability || fundSources.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 12),
                    ValueListenableBuilder<int?>(
                      valueListenable: fundingSourceId,
                      builder: (context, value, _) => DropdownButtonFormField<int?>(
                        initialValue: value,
                        decoration: terminalDecoration('资金来源（可选）'),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('不选（资金已在该产品中）'),
                          ),
                          for (final h in fundSources)
                            DropdownMenuItem(
                              value: h.id,
                              child: Text(
                                _fundingSourceLabel(h),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => fundingSourceId.value = v,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '选择后保存时将自动从该来源赎回对应金额',
                        style: T.label(size: 12, color: T.text2),
                      ),
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
            var type = assetType.value;
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
            // The picker's single "基金" entry is stored as 场外基金 by
            // default; an on-exchange code resolves it to 场内基金 (etf)
            // with the prefixed symbol. 沪市场内 funds occupy 500-518 (the
            // 519xxx range is off-exchange open-end funds and must NOT be
            // promoted — sina would never find the code); 深市场内 funds
            // are 159xxx (ETF) and 16xxxx/18xxxx (LOF/封闭式). Other codes
            // keep the raw symbol and the eastmoney NAV.
            if (type == AssetType.mutualFund &&
                symbol != null &&
                symbol.isNotEmpty) {
              final normalized = normalizeSinaSymbol(symbol);
              final bare = normalized.length > 2 && normalized.startsWith('sz')
                  ? normalized.substring(2)
                  : normalized;
              final isOnExchange = normalized.startsWith('sh')
                      && !normalized.startsWith('sh519') ||
                  (normalized.startsWith('sz') &&
                      bare.length == 6 &&
                      (bare.startsWith('159') ||
                          bare.startsWith('16') ||
                          bare.startsWith('18')));
              if (isOnExchange) {
                type = AssetType.etf;
                symbol = normalized;
              }
            }
            final hasSymbol = symbol != null && symbol.isNotEmpty;
            // Only persist the category when it differs from the type's
            // natural one: an override equal to the default is noise, and
            // storing it would pin the category against a later type change.
            final pickedCategory = categoryOverride.value;
            final Value<String?> categoryOverrideValue =
                (type == AssetType.liability ||
                        pickedCategory == null ||
                        pickedCategory == type.category)
                    ? const Value<String?>.absent()
                    : Value(pickedCategory.storageName);
            // `forex` means "priced by a currency rate" — only a
            // 银行理财 whose *code* is a currency (e.g. USD) qualifies.
            // A product code (Y05A9W10006A) has no live quote: it is a
            // manual holding that converts by FX like any other foreign one.
            final marketSource = switch (type) {
              AssetType.stock || AssetType.etf => 'sina',
              AssetType.mutualFund => 'eastmoney',
              AssetType.gold => 'sge',
              AssetType.crypto => 'coingecko',
              AssetType.bankWealth when isFxCurrencyCode(symbol) => 'forex',
              _ => 'manual',
            };
            final rateLinked =
                marketSource == 'forex' && isFxCurrencyCode(symbol);
            final userPrice = double.tryParse(latestPriceCtrl.text.trim());
            // Currency is a free label even for FX-linked holdings (the
            // rate lives in the unit price); everything else takes the
            // user-chosen currency so USD holdings stay USD.
            final finalCurrency = currencyCtrl.text.trim().toUpperCase().isEmpty
                ? 'CNY'
                : currencyCtrl.text.trim().toUpperCase();
            // Funding source: redeem from an existing holding to fund this
            // new one. Validated before creation so a mismatch never
            // leaves a half state.
            int? redemptionSourceId;
            double redemptionAmount = 0;
            final selectedSource = fundingSourceId.value;
            if (selectedSource != null) {
              for (final h in holdings) {
                if (h.id != selectedSource) continue;
                final st = AssetType.fromStorage(h.assetType);
                if (st == AssetType.liability) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('负债不能作为资金来源')),
                    );
                  }
                  return;
                }
                redemptionAmount = isAmount
                    ? qty
                    : qty * (invested ?? 0);
                if (h.currency != finalCurrency) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('资金来源「${h.name}」币种与持仓币种不一致'),
                      ),
                    );
                  }
                  return;
                }
                redemptionSourceId = h.id;
                break;
              }
            }
            int createdId;
            try {
              final fx = double.tryParse(fxRateCtrl.text.trim());
              createdId = await dao.createHolding(HoldingsCompanion.insert(
                accountId: accountId.value!,
                name: name,
                assetType: type.storageName,
                marketSource: Value(marketSource),
                categoryOverride: categoryOverrideValue,
                symbol: hasSymbol ? Value(symbol) : const Value.absent(),
                quantity: Value(qty),
                costPrice: Value(isAmount
                    ? (type.isAmountBased
                        ? (investedResult ?? qty)
                        : 1) // liability: unit price 1, cost = balance
                    : (invested ?? 0)),
                latestPrice: Value(isAmount ? 1 : (userPrice ?? 0)),
                costFxRate:
                    finalCurrency != 'CNY' && !rateLinked && fx != null && fx > 0
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
            if (redemptionSourceId != null) {
              final redemption = await ref
                  .read(transactionServiceProvider)
                  .recordRedemption(
                sourceHoldingId: redemptionSourceId,
                amount: redemptionAmount,
                currency: finalCurrency,
                note: '赎回购买 $name',
              );
              if (!redemption.ok) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          '持仓已创建，但来源赎回记录失败：${redemption.message ?? ''}'),
                      backgroundColor: T.up,
                    ),
                  );
                }
                return;
              }
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
  // A storage name this version does not know (e.g. synced from a newer
  // release): display it and keep it unchanged on save — silently
  // rewriting it to the fallback type (cash) would corrupt the row and
  // propagate the damage to every other device via sync.
  final unknownType =
      !AssetType.values.any((t) => t.storageName == holding.assetType);
  final typeNotifier = ValueNotifier<AssetType>(initialType);
  final accountIdNotifier = ValueNotifier<int>(holding.accountId);
  final riskLevelNotifier = ValueNotifier<String?>(holding.riskLevel);
  // Manual allocation-category override; null = follow the asset type.
  final categoryNotifier = ValueNotifier<AssetCategory?>(
    AssetCategory.fromStorageOrNull(holding.categoryOverride),
  );
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
                if (unknownType)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '⚠️ 持仓类型「${holding.assetType}」来自更新版本的 App，'
                      '当前版本无法识别。已锁定类型，以免保存时数据被降级。',
                      style: T.label(size: 12, color: T.warning),
                    ),
                  ),
                DropdownButtonFormField<AssetType>(
                  initialValue: type,
                  decoration: terminalDecoration('资产类型'),
                  items: [
                    for (final t in AssetType.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: unknownType
                      ? null
                      : (v) {
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
                if (!isLiability) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue:
                        categoryNotifier.value?.storageName ?? 'auto',
                    decoration: terminalDecoration('配置归类'),
                    items: [
                      const DropdownMenuItem(
                        value: 'auto',
                        child: Text('自动（按资产类型）'),
                      ),
                      for (final c in AssetCategory.values)
                        DropdownMenuItem(
                          value: c.storageName,
                          child: Text(c.label),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      categoryNotifier.value = v == 'auto'
                          ? null
                          : AssetCategory.fromStorageOrNull(v);
                    }),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      '决定资产配置、配置比例告警与品类筛选里的归类。'
                      '黄金ETF / 商品ETF 等请在此指定标的归类。',
                      style: TextStyle(fontSize: 11.5, color: T.text3),
                    ),
                  ),
                ],
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
                // Rate-linked bank wealth (the *code* is a currency, e.g.
                // USD) embeds the live rate in its unit price, so the
                // currency field is a free label — always editable, no
                // forced CNY, and switching it never needs number
                // conversion (the quantity is the foreign amount already).
                // A product code (Y05A9W10006A) is NOT rate-linked: it is an
                // ordinary foreign-currency holding that converts by FX.
                ListenableBuilder(
                  listenable: Listenable.merge([typeNotifier, symbolCtrl]),
                  builder: (context, _) {
                    final forexLinked =
                        typeNotifier.value == AssetType.bankWealth &&
                            isFxCurrencyCode(symbolCtrl.text);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TerminalTextField(
                          controller: currencyCtrl,
                          label: forexLinked
                              ? '币种 (ISO 代码) · 汇率联动'
                              : '币种 (ISO 代码)',
                          hint: forexLinked
                              ? '单价将随汇率自动更新（单价=汇率）；币种为标记，市值=数量×汇率'
                              : '默认人民币 CNY；外币请填 ISO 代码（如 USD），市值将按汇率折算',
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
                                hint: (fxRates[ccy] == null || (fxRates[ccy] ?? 0) <= 0)
                                    ? '该币种暂无自动汇率，市值将按 1:1 折算；请填写买入时汇率'
                                    : '默认已填当前汇率，可改为真实买入汇率',
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                              ),
                            );
                          },
                        ),
                        if (!forexLinked &&
                            currencyCtrl.text.trim().toUpperCase() !=
                                holding.currency) ...[
                          const SizedBox(height: 8),
                          Text(
                            '⚠️ 仅切换币种标签：数量 / 成本单价 / 最新净值不会自动换算，'
                            '请确认这些字段已按新币种填写',
                            style: T.label(size: 12, color: T.warning),
                          ),
                        ],
                      ],
                    );
                  },
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
    final qty = double.tryParse(quantityCtrl.text.trim());
    if (qty == null) return;
    final cost = double.tryParse(costCtrl.text.trim());
    final price = double.tryParse(priceCtrl.text.trim());
    if (!isAmount && (cost == null || price == null)) return;
    var symbol = symbolCtrl.text.trim();
    // Normalize bare 6-digit A-share/ETF codes (5/6 -> sh, 0/1/3 -> sz),
    // matching the add dialog so price_cache keys stay consistent with
    // what MarketService writes.
    if (!isAmount && (type == AssetType.stock || type == AssetType.etf)) {
      symbol = normalizeSinaSymbol(symbol);
    }
    // Market source follows the new asset type; amount-based assets are
    // manual by nature. A symbol change on a share holding with an empty
    // source also re-derives the source. An unknown stored type keeps its
    // original source untouched (see unknownType above).
    final marketSource = unknownType
        ? holding.marketSource
        : isAmount
            ? 'manual'
            : MarketSource.fromStorage(holding.marketSource) == MarketSource.manual
                ? switch (type) {
                    AssetType.stock || AssetType.etf => 'sina',
                    AssetType.mutualFund => 'eastmoney',
                    AssetType.gold => 'sge',
                    AssetType.crypto => 'coingecko',
                    // Manual 银行理财 stays manual unless the code is a
                    // currency — only then is the unit price the rate
                    // (isFxLinked); a product code keeps manual pricing.
                    AssetType.bankWealth => isFxCurrencyCode(symbol)
                        ? 'forex'
                        : holding.marketSource,
                    _ => holding.marketSource,
                  }
                : switch (type) {
                    AssetType.stock || AssetType.etf => 'sina',
                    AssetType.mutualFund => 'eastmoney',
                    AssetType.gold => 'sge',
                    AssetType.crypto => 'coingecko',
                    AssetType.bond => 'manual',
                    AssetType.futures => 'manual',
                    AssetType.bankWealth =>
                      isFxCurrencyCode(symbol) ? 'forex' : 'manual',
                    AssetType.cash ||
                    AssetType.bankDeposit ||
                    AssetType.liquidWealth ||
                    AssetType.liability ||
                    AssetType.property =>
                      'manual',
                  };
    // Only forex-linked holdings are priced in CNY by construction; other
    // holdings keep the user-chosen currency (e.g. USD stocks stay USD).
    // Only a currency code makes the unit price BE the rate (see
    // isFxLinked): there the purchase rate already lives in the unit price,
    // so the cost-fx-rate field stays empty. A product code (a USD NAV
    // product) is an ordinary foreign holding and keeps its recorded
    // purchase rate — dropping it would silently re-convert the cost at
    // today's rate on every save.
    final autoCny =
        unknownType ? false : marketSource == 'forex' && isFxCurrencyCode(symbol);
    // Currency is a free label (even for rate-linked holdings), so always
    // take the user's value.
    final updated = holding.copyWith(
      accountId: accountIdNotifier.value,
      name: nameCtrl.text.trim().isEmpty ? holding.name : nameCtrl.text.trim(),
      assetType: unknownType ? holding.assetType : type.storageName,
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
      // Only keep an override that actually differs from the type's natural
      // category; an unknown stored type keeps whatever it already had.
      categoryOverride: unknownType
          ? Value(holding.categoryOverride)
          : (type == AssetType.liability ||
                  categoryNotifier.value == null ||
                  categoryNotifier.value == type.category)
              ? const Value.absent()
              : Value(categoryNotifier.value!.storageName),
      // An unknown stored type keeps its original symbol regardless of the
      // fallback display form.
      symbol: unknownType
          ? Value(holding.symbol)
          : !isAmount
              ? (symbol.isEmpty ? const Value.absent() : Value(symbol))
              : const Value.absent(),
      currency: currencyCtrl.text.trim().toUpperCase().isEmpty
          ? holding.currency
          : currencyCtrl.text.trim().toUpperCase(),
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
