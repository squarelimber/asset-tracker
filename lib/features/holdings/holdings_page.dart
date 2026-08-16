import 'package:drift/drift.dart' hide Column, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../core/history_sync.dart';
import '../../core/responsive.dart';
import '../../core/symbols.dart';
import '../../data/database.dart';
import '../transactions/transaction_dialogs.dart';
import 'invested_profit_field.dart';
import 'purchase_date_field.dart';

final _refreshingProvider = StateProvider<bool>((ref) => false);

/// Sort modes for the holdings list.
enum HoldingSort {
  defaultOrder('默认'),
  amountDesc('市值从高到低'),
  amountAsc('市值从低到高'),
  nameAsc('名称 A-Z');

  const HoldingSort(this.label);

  final String label;
}

double _holdingMarketValue(HoldingRow h) {
  final type = AssetType.fromStorage(h.assetType);
  return type.isAmountBased ? h.quantity : h.quantity * h.latestPrice;
}

/// Today's profit for a holding from its cached quote: the cached unit
/// price change x quantity. Returns null when the quote is missing or the
/// cache was not written today (stale data would be misleading).
double? todayProfitOf(PriceCacheRow? row, double quantity, {DateTime? now}) {
  if (row == null || row.change == null) return null;
  final fetched = row.fetchedAt;
  final n = now ?? DateTime.now();
  if (fetched.year != n.year ||
      fetched.month != n.month ||
      fetched.day != n.day) {
    return null;
  }
  return row.change! * quantity;
}

/// Today's change percentage (fraction) from the cached quote, or null.
double? todayChangePctOf(PriceCacheRow? row, {DateTime? now}) {
  if (row == null || row.changePct == null) return null;
  final fetched = row.fetchedAt;
  final n = now ?? DateTime.now();
  if (fetched.year != n.year ||
      fetched.month != n.month ||
      fetched.day != n.day) {
    return null;
  }
  return row.changePct;
}

/// CNY-converted market value of non-liability holdings.
double assetTotalOf(List<HoldingRow> holdings, Map<String, double> rates) {
  return holdings.fold(0.0, (sum, h) {
    final type = AssetType.fromStorage(h.assetType);
    if (type == AssetType.liability) return sum;
    final rate = rates[h.currency.toUpperCase()] ?? 1;
    return sum +
        (type.isAmountBased ? h.quantity : h.quantity * h.latestPrice) * rate;
  });
}

/// CNY-converted total outstanding balance of liability holdings.
double liabilityTotalOf(List<HoldingRow> holdings, Map<String, double> rates) {
  return holdings.fold(0.0, (sum, h) {
    if (AssetType.fromStorage(h.assetType) != AssetType.liability) return sum;
    final rate = rates[h.currency.toUpperCase()] ?? 1;
    return sum + h.quantity * rate;
  });
}

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

class HoldingsPage extends ConsumerStatefulWidget {
  const HoldingsPage({super.key});

  @override
  ConsumerState<HoldingsPage> createState() => _HoldingsPageState();
}

enum _HoldingSection { assets, liabilities }

class _HoldingsPageState extends ConsumerState<HoldingsPage> {
  _HoldingSection _section = _HoldingSection.assets;
  HoldingSort _sort = HoldingSort.defaultOrder;
  bool _searching = false;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Auto-refresh quotes shortly after opening so existing holdings
    // show up-to-date NAV without any manual action.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) _refresh(showSnack: false);
      });
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<HoldingRow> _sorted(List<HoldingRow> list) {
    final filtered = _query.trim().isEmpty
        ? [...list]
        : list
            .where((h) =>
                h.name.toLowerCase().contains(_query.toLowerCase()) ||
                (h.symbol ?? '').toLowerCase().contains(_query.toLowerCase()))
            .toList();
    switch (_sort) {
      case HoldingSort.defaultOrder:
        break;
      case HoldingSort.amountDesc:
        filtered.sort((a, b) => _holdingMarketValue(b).compareTo(_holdingMarketValue(a)));
      case HoldingSort.amountAsc:
        filtered.sort((a, b) => _holdingMarketValue(a).compareTo(_holdingMarketValue(b)));
      case HoldingSort.nameAsc:
        filtered.sort((a, b) => a.name.compareTo(b.name));
    }
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final holdings = ref.watch(holdingsProvider);
    final refreshing = ref.watch(_refreshingProvider);
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索名称或代码',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : const Text('持仓'),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) {
                _query = '';
                _searchCtrl.clear();
              }
            }),
          ),
          PopupMenuButton<HoldingSort>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => [
              for (final s in HoldingSort.values)
                PopupMenuItem(value: s, child: Text(s.label)),
            ],
          ),
          IconButton(
            tooltip: '刷新行情',
            onPressed: refreshing ? null : () => _refresh(showSnack: true),
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
        data: (list) {
          if (list.isEmpty) return const _EmptyHoldings();
          final sorted = _sorted(list);
          final assets = sorted
              .where((h) =>
                  AssetType.fromStorage(h.assetType) != AssetType.liability)
              .toList();
          final liabilities = sorted
              .where((h) =>
                  AssetType.fromStorage(h.assetType) == AssetType.liability)
              .toList()
            ..sort((a, b) =>
                _holdingMarketValue(b).compareTo(_holdingMarketValue(a)));
          final rates = ref.watch(cnyRatesProvider).value ?? const {};
          final isAssets = _section == _HoldingSection.assets;
          return ResponsiveShell(
            child: ListView(
              children: [
                Center(
                  child: SegmentedButton<_HoldingSection>(
                    segments: const [
                      ButtonSegment(
                        value: _HoldingSection.assets,
                        label: Text('资产'),
                        icon: Icon(Icons.account_balance_wallet_outlined, size: 18),
                      ),
                      ButtonSegment(
                        value: _HoldingSection.liabilities,
                        label: Text('负债'),
                        icon: Icon(Icons.credit_card_outlined, size: 18),
                      ),
                    ],
                    selected: {_section},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.comfortable,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onSelectionChanged: (s) =>
                        setState(() => _section = s.first),
                  ),
                ),
                const SizedBox(height: 16),
                if (isAssets) ...[
                  _SectionHeader(
                    title: '资产',
                    total: assetTotalOf(assets, rates),
                  ),
                  if (assets.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('暂无资产')),
                    )
                  else
                    ResponsiveGrid(
                      children: [
                        for (final h in assets) _HoldingCard(holding: h),
                      ],
                    ),
                ] else if (liabilities.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('暂无负债')),
                  )
                else ...[
                  _SectionHeader(
                    title: '负债',
                    total: liabilityTotalOf(liabilities, rates),
                    isLiability: true,
                  ),
                  ResponsiveGrid(
                    children: [
                      for (final h in liabilities) _HoldingCard(holding: h),
                    ],
                  ),
                ],
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }

  Future<void> _refresh({bool showSnack = true}) async {
    ref.read(_refreshingProvider.notifier).state = true;
    final result = await ref.read(marketServiceProvider).refreshAll();
    // FX rates may have changed with the refresh.
    ref.invalidate(cnyRatesProvider);
    ref.invalidate(priceCacheProvider);
    ref.read(_refreshingProvider.notifier).state = false;
    if (!mounted) return;
    if (showSnack) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.failed == 0
              ? '行情已更新 (${result.updated} 项)'
              : '更新 ${result.updated} 项，失败 ${result.failed} 项'),
        ),
      );
    }
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
              ValueListenableBuilder<AssetType>(
                valueListenable: assetType,
                builder: (context, value, _) => DropdownButtonFormField<String>(
                  initialValue: 'auto',
                  decoration: const InputDecoration(labelText: '风险等级'),
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
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '名称'),
              ),
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
                        TextField(
                          controller: quantityCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(
                            labelText: isLiability ? '当前欠款金额' : '当前金额',
                            hintText: isLiability ? '如 3000' : '如 50000',
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
                      TextField(
                        controller: symbolCtrl,
                        decoration: InputDecoration(
                          labelText: symbolEnabled ? '行情代码' : '（手动净值资产无需代码）',
                          hintText: switch (type) {
                            AssetType.stock || AssetType.etf => '如 510880 / 159915（自动识别沪/深）',
                            AssetType.mutualFund => '如 110022',
                            AssetType.gold => 'AU99.99（自动金价）',
                            AssetType.crypto => '如 bitcoin',
                            AssetType.bankWealth => '填外汇代码如 USD 可自动汇率联动，留空手动净值',
                            _ => null,
                          },
                        ),
                        enabled: symbolEnabled,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: quantityCtrl,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration:
                            const InputDecoration(labelText: '数量 / 份额 / 克数'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: costPriceCtrl,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: '成本单价'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: latestPriceCtrl,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: '最新净值（可选）',
                          hintText: type.isMarketLinked
                              ? '留空则保存后自动获取'
                              : '手动净值资产建议填写',
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
                    return const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '币种：人民币（行情自动折算）',
                        style: TextStyle(fontSize: 13),
                      ),
                    );
                  }
                  return Column(
                    children: [
                      TextField(
                        controller: currencyCtrl,
                        decoration: const InputDecoration(labelText: '币种 (ISO 代码)'),
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
                            child: TextField(
                              controller: fxRateCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: InputDecoration(
                                labelText: '买入时汇率（$ccy/CNY）',
                                hintText: '默认已填当前汇率，可改为真实买入汇率',
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
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.total,
    this.isLiability = false,
  });

  final String title;
  final double total;
  final bool isLiability;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          Text(
            '¥${Formats.amount(total)}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: isLiability
                      ? AppColors.down
                      : Theme.of(context).colorScheme.onSurface,
                ),
          ),
        ],
      ),
    );
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

  static String _holdingAge(HoldingRow h) =>
      Formats.holdingDuration(h.purchaseDate ?? h.createdAt);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = AssetType.fromStorage(holding.assetType);
    final marketValue =
        type.isAmountBased ? holding.quantity : holding.quantity * holding.latestPrice;
    final cost = type.isAmountBased
        ? (holding.costPrice > 0 ? holding.costPrice : holding.quantity)
        : holding.quantity * holding.costPrice;
    final profit = marketValue - cost;
    final profitPct = cost == 0 ? 0.0 : profit / cost;
    // Today's change from the price cache (only when written today).
    final cache = ref.watch(priceCacheProvider).value ?? const <String, PriceCacheRow>{};
    final cacheSymbol = cacheSymbolFor(holding);
    final todayRow = cacheSymbol == null ? null : cache[cacheSymbol];
    final todayProfit = todayProfitOf(todayRow, holding.quantity);
    final todayPct = todayChangePctOf(todayRow);
    // Account name for disambiguating the same security across accounts.
    final accounts = ref.watch(accountsProvider).value ?? const <AccountRow>[];
    final accountName = accounts
        .where((a) => a.id == holding.accountId)
        .map((a) => a.name)
        .firstOrNull;

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
                        Text(
                          holding.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          type == AssetType.liability
                              ? '负债 · 起始 ${Formats.date(holding.purchaseDate ?? holding.createdAt)}'
                              : type.isAmountBased
                                  ? '持有 ${_holdingAge(holding)}'
                                  : '${holding.symbol ?? '手动净值'} · 持有 ${_holdingAge(holding)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (accountName != null)
                          Text(
                            accountName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
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
                          if (!type.isAmountBased) {
                            _showUpdatePriceDialog(context, ref);
                          }
                        case 'delete':
                          _confirmDelete(context, ref);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('编辑')),
                      if (!type.isAmountBased)
                        const PopupMenuItem(value: 'update_price', child: Text('更新单价')),
                      const PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                Formats.money(marketValue, holding.currency),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: type == AssetType.liability
                          ? AppColors.down
                          : null,
                    ),
              ),
              const SizedBox(height: 4),
              if (type == AssetType.liability)
                // Liabilities have no cost basis / return rate; only the
                // outstanding balance and today's row are shown.
                const SizedBox(height: 12)
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${profit >= 0 ? '+' : ''}${Formats.money(profit, holding.currency)}',
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
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '成本 ${Formats.money(cost, holding.currency)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              if (type != AssetType.liability) ...[
                const SizedBox(height: 6),
                // Always rendered (placeholder when there is no quote data)
                // so every card keeps the same height and grid rows align.
                // "最新" = the latest trading day's change (not necessarily
                // today, e.g. on weekends).
                Row(
                  children: [
                    Text(
                      '最新',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (todayProfit == null)
                            Text(
                              '--',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                            )
                          else ...[
                            Text(
                              '${todayProfit >= 0 ? '+' : ''}${Formats.money(todayProfit, holding.currency)}',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: context.changeColor(todayProfit),
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            if (todayPct != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                '(${Formats.pct(todayPct)})',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: context.changeColor(todayProfit),
                                    ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ],
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
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<int>(
                    valueListenable: accountIdNotifier,
                    builder: (context, accountId, _) =>
                        DropdownButtonFormField<int>(
                      initialValue: accountId,
                      decoration: const InputDecoration(labelText: '所属账户'),
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
                    decoration: const InputDecoration(labelText: '资产类型'),
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
                    decoration: const InputDecoration(labelText: '风险等级'),
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
                    TextField(
                      controller: symbolCtrl,
                      decoration: InputDecoration(
                        labelText: '行情代码',
                        hintText: '如 sh600519 / 110022 / AU99.99 / USD',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: quantityCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: isLiability
                          ? '当前欠款金额'
                          : (isAmount ? '当前金额' : '数量 / 份额 / 克数'),
                    ),
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
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '币种：人民币（行情自动折算）',
                        style: TextStyle(fontSize: 13),
                      ),
                    )
                  else
                    Column(
                      children: [
                        TextField(
                          controller: currencyCtrl,
                          decoration: const InputDecoration(labelText: '币种 (ISO 代码)'),
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
                              child: TextField(
                                controller: fxRateCtrl,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: InputDecoration(
                                  labelText: '买入时汇率（$ccy/CNY）',
                                  hintText: '默认已填当前汇率，可改为真实买入汇率',
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    decoration: const InputDecoration(labelText: '备注'),
                  ),
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
      ref.read(daoProvider).setSetting(historySyncDirtyKey, historyDirtySet);
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
    final type = AssetType.fromStorage(holding.assetType);
    final marketValue =
        type.isAmountBased ? holding.quantity : holding.quantity * holding.latestPrice;
    final cost = type.isAmountBased
        ? (holding.costPrice > 0 ? holding.costPrice : holding.quantity)
        : holding.quantity * holding.costPrice;
    final profitPct = cost == 0 ? 0.0 : (marketValue - cost) / cost;
    final buyDate = holding.purchaseDate ?? holding.createdAt;
    final days = DateTime.now().difference(buyDate).inDays;
    final annualized = Formats.annualizedReturn(profitPct, days);
    final cache = ref.watch(priceCacheProvider).value ?? const <String, PriceCacheRow>{};
    final cacheSymbol = cacheSymbolFor(holding);
    final todayRow = cacheSymbol == null ? null : cache[cacheSymbol];
    final todayProfit = todayProfitOf(todayRow, holding.quantity);
    final todayPct = todayChangePctOf(todayRow);
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                holding.name,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: () => showHoldingTransactionDialog(context, ref, holding),
              icon: const Icon(Icons.edit_note, size: 18),
              label: const Text('记一笔'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                if (type == AssetType.liability)
                  // Liabilities have no cost basis / return rate.
                  _InfoRow(
                    label: '当前欠款',
                    value: Formats.money(marketValue, holding.currency),
                    valueColor: AppColors.down,
                  )
                else if (type.isAmountBased) ...[
                  _InfoRow(label: '当前金额', value: Formats.money(marketValue, holding.currency)),
                  _InfoRow(label: '累计投入', value: Formats.money(cost, holding.currency)),
                  _InfoRow(
                    label: '收益',
                    value: '${profitPct >= 0 ? '+' : ''}${Formats.money(marketValue - cost, holding.currency)}'
                        ' (${Formats.pct(profitPct)})',
                    valueColor: context.changeColor(marketValue - cost),
                  ),
                ] else ...[
                  _InfoRow(label: '最新单价', value: holding.latestPrice.toStringAsFixed(4)),
                  _InfoRow(label: '成本单价', value: holding.costPrice.toStringAsFixed(4)),
                  _InfoRow(label: '数量/份额', value: Formats.smartNum(holding.quantity)),
                ],
                _InfoRow(label: '币种', value: holding.currency),
                _InfoRow(
                  label: type == AssetType.liability ? '开卡日期' : '买入日期',
                  value: Formats.date(buyDate),
                ),
                if (type != AssetType.liability)
                  _InfoRow(label: '持有时间', value: Formats.holdingDuration(buyDate)),
                if (todayProfit != null)
                  _InfoRow(
                    label: '最新收益',
                    value: todayPct == null
                        ? '${todayProfit >= 0 ? '+' : ''}${Formats.money(todayProfit, holding.currency)}'
                        : '${todayProfit >= 0 ? '+' : ''}${Formats.money(todayProfit, holding.currency)}'
                            ' (${Formats.pct(todayPct)})',
                    valueColor: context.changeColor(todayProfit),
                  ),
                if (annualized != null && type != AssetType.liability)
                  _InfoRow(
                    label: '年化收益率',
                    value: Formats.pct(annualized),
                    valueColor: context.changeColor(annualized),
                  ),
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
                      _TransactionTile(txn: t, costPrice: holding.costPrice),
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
  const _InfoRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600, color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionTile extends ConsumerWidget {
  const _TransactionTile({required this.txn, this.costPrice});

  final TransactionRow txn;
  final double? costPrice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = TransactionType.fromStorage(txn.type);
    final isIn = type == TransactionType.buy ||
        type == TransactionType.transferIn ||
        type == TransactionType.income ||
        type == TransactionType.dividend;
    final isSplit = type == TransactionType.split;
    final realized = type == TransactionType.sell &&
            costPrice != null &&
            txn.quantity != null
        ? (txn.price! - costPrice!) * txn.quantity!
        : null;
    return Card(
      child: ListTile(
        dense: true,
        leading: Icon(
          type.icon,
          size: 20,
          color: isSplit
              ? Theme.of(context).colorScheme.outline
              : context.changeColor(isIn ? 1 : -1),
        ),
        title: Text(type.label),
        subtitle: Text(
          realized == null
              ? Formats.dateTime(txn.occurredAt.toLocal())
              : '${Formats.dateTime(txn.occurredAt.toLocal())} · 落袋 '
                  '${realized >= 0 ? '+' : ''}${Formats.money(realized, txn.currency)}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                isSplit
                    ? '×${Formats.smartNum(txn.amount)}'
                    : '${isIn ? '+' : '-'}${Formats.money(txn.amount, txn.currency)}',
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: isSplit
                      ? Theme.of(context).colorScheme.outline
                      : context.changeColor(isIn ? 1 : -1),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: '删除流水（自动回滚持仓）',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('删除流水'),
                    content: const Text('删除后持仓会自动回滚到该笔交易前的状态。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: AppColors.up),
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (ok != true || !context.mounted) return;
                final result =
                    await ref.read(transactionServiceProvider).remove(txn.id);
                if (!context.mounted) return;
                if (result.ok) {
                  ref.read(daoProvider).setSetting(historySyncDirtyKey, historyDirtySet);
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(result.ok ? '已删除并回滚' : (result.message ?? '删除失败')),
                    backgroundColor: result.ok ? null : AppColors.up,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
