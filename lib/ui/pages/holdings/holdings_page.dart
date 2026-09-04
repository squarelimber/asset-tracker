import 'dart:async';

import 'package:flutter/material.dart' hide DataRow;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../core/symbols.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../components/app_bar_actions.dart';
import '../../components/data_row.dart';
import '../../components/delta_text.dart';
import '../../components/empty_state.dart';
import '../../components/section_header.dart';
import '../../components/status_chip.dart';
import '../../components/terminal_card.dart';
import '../../components/terminal_fab.dart';
import '../../tokens.dart';
import 'holding_detail_sheet.dart';
import 'holding_dialogs.dart';
import 'holdings_table.dart';

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

/// Lifecycle filters for the holdings list. 「全部」hides archived rows
/// (they stay reachable through the 已归档 filter and the detail sheet).
enum HoldingFilter {
  all('全部'),
  active('仅当前持仓'),
  closed('仅已清仓'),
  archived('已归档');

  const HoldingFilter(this.label);

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

class HoldingsPage extends ConsumerStatefulWidget {
  const HoldingsPage({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  ConsumerState<HoldingsPage> createState() => _HoldingsPageState();
}

class _HoldingsPageState extends ConsumerState<HoldingsPage> {
  HoldingSection _section = HoldingSection.assets;
  HoldingSort _sort = HoldingSort.defaultOrder;
  HoldingFilter _filter = HoldingFilter.all;
  bool _searching = false;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _query = widget.initialQuery!;
      _searchCtrl.text = _query;
      _searching = true;
    }
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

  bool _matchesFilter(HoldingRow h) {
    switch (_filter) {
      case HoldingFilter.all:
        return !h.archived;
      case HoldingFilter.active:
        return !h.archived && !isHoldingClosed(h);
      case HoldingFilter.closed:
        return !h.archived && isHoldingClosed(h);
      case HoldingFilter.archived:
        return h.archived;
    }
  }

  List<HoldingRow> _sorted(List<HoldingRow> list) {
    var filtered = _query.trim().isEmpty
        ? [...list]
        : list
            .where((h) =>
                h.name.toLowerCase().contains(_query.toLowerCase()) ||
                (h.symbol ?? '').toLowerCase().contains(_query.toLowerCase()))
            .toList();
    filtered = filtered.where(_matchesFilter).toList();
    switch (_sort) {
      case HoldingSort.defaultOrder:
        // Active holdings keep their database order; fully exited ones sink
        // to the bottom, most recently touched first.
        final active = filtered.where((h) => !isHoldingClosed(h)).toList();
        final closed = filtered.where(isHoldingClosed).toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return [...active, ...closed];
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
          const TerminalAppBarActions(),
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
          PopupMenuButton<HoldingFilter>(
            tooltip: '筛选',
            icon: Icon(
              _filter == HoldingFilter.all ? Icons.filter_list : Icons.filter_alt,
              color: _filter == HoldingFilter.all ? null : T.accent,
            ),
            initialValue: _filter,
            onSelected: (f) => setState(() => _filter = f),
            itemBuilder: (_) => [
              for (final f in HoldingFilter.values)
                PopupMenuItem(value: f, child: Text(f.label)),
            ],
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
      floatingActionButton: TerminalFab(
        onPressed: () => showAddHoldingDialog(context, ref),
        icon: Icons.add,
        label: '添加持仓',
      ),
      body: holdings.when(
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              message: '还没有持仓\n点击右下角按钮添加第一个持仓',
            );
          }
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
          final isAssets = _section == HoldingSection.assets;
          return ResponsiveShell(
            child: Responsive.isDesktop(context)
                ? HoldingsTable(
                    section: _section,
                    assets: assets,
                    liabilities: liabilities,
                    rates: rates,
                    onHoldingTap: (h) => showHoldingDetailSheet(context, ref, h),
                  )
                : ListView(
                    padding: const EdgeInsets.all(T.s3),
                    children: [
                      SegmentedButton<HoldingSection>(
                        segments: const [
                          ButtonSegment(value: HoldingSection.assets, label: Text('资产')),
                          ButtonSegment(
                            value: HoldingSection.liabilities,
                            label: Text('负债'),
                          ),
                        ],
                        selected: {_section},
                        onSelectionChanged: (s) =>
                            setState(() => _section = s.first),
                        showSelectedIcon: false,
                      ),
                      const SizedBox(height: T.s3),
                      if (isAssets) ...[
                        SectionHeader(
                          label: '资产',
                          trailing: Text(
                            Formats.amount(assetTotalOf(assets, rates)),
                            style: T.mono(size: 13, weight: FontWeight.w600),
                          ),
                        ),
                        if (assets.isEmpty)
                          EmptyState(
                            message: _filter == HoldingFilter.all
                                ? '暂无资产'
                                : '没有符合条件的持仓',
                          )
                        else
                          for (final h in assets)
                            _HoldingRowCard(
                              holding: h,
                              onTap: () => showHoldingDetailSheet(context, ref, h),
                            ),
                      ] else ...[
                        SectionHeader(
                          label: '负债',
                          trailing: Text(
                            Formats.amount(liabilityTotalOf(liabilities, rates)),
                            style: T.mono(size: 13, weight: FontWeight.w600, color: T.down),
                          ),
                        ),
                        if (liabilities.isEmpty)
                          EmptyState(
                            message: _filter == HoldingFilter.all
                                ? '暂无负债'
                                : '没有符合条件的持仓',
                          )
                        else
                          for (final h in liabilities)
                            _HoldingRowCard(
                              holding: h,
                              onTap: () => showHoldingDetailSheet(context, ref, h),
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
    // Prices are fresh: re-evaluate alert rules and notify for anything
    // newly fired (no-op when disabled or nothing changed today).
    unawaited(ref.read(alertNotificationServiceProvider).checkAndNotify());
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
}

class _HoldingRowCard extends ConsumerWidget {
  const _HoldingRowCard({required this.holding, required this.onTap});

  final HoldingRow holding;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = AssetType.fromStorage(holding.assetType);
    final marketValue = _holdingMarketValue(holding);
    // Today's change from the price cache (only when written today).
    final cache = ref.watch(priceCacheProvider).value ?? const <String, PriceCacheRow>{};
    final cacheSymbol = cacheSymbolFor(holding);
    final todayRow = cacheSymbol == null ? null : cache[cacheSymbol];
    final todayProfit = todayProfitOf(todayRow, holding.quantity);
    final todayPct = todayChangePctOf(todayRow);
    final hide = ref.watch(hideAmountsProvider);
    final closed = isHoldingClosed(holding);
    final subtitle = closed
        ? (type == AssetType.liability
            ? '已还清'
            : type.isAmountBased
                ? '已结清'
                : '清仓 · ${holding.symbol ?? '手动净值'}')
        : type == AssetType.liability
            ? '负债 · 起始 ${Formats.date(holding.purchaseDate ?? holding.createdAt)}'
            : type.isAmountBased
                ? '持有 ${Formats.holdingDuration(holding.purchaseDate ?? holding.createdAt)}'
                : '${holding.symbol ?? '手动净值'} · 持有 ${Formats.holdingDuration(holding.purchaseDate ?? holding.createdAt)}';
    return TerminalCard(
      onTap: onTap,
      child: DataRow(
        title: holding.name,
        titleSuffix: closed
            ? StatusChip(closedHoldingLabel(holding))
            : (holding.archived ? const StatusChip('已归档') : null),
        dimmed: closed || holding.archived,
        subtitle: Text(subtitle, style: T.label(size: 11, color: T.text3)),
        leading: Icon(type.icon, size: 16, color: type.color),
        showChevron: true,
        trailing: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              hide ? '****' : Formats.money(marketValue, holding.currency),
              style: T.mono(
                size: 14,
                color: type == AssetType.liability ? T.down : T.text1,
              ),
            ),
            if (todayProfit == null)
              Text('--', style: T.mono(size: 12, color: T.text3))
            else
              DeltaText(
                value: todayPct ?? 0,
                text: hide
                    ? '****'
                    : '${todayProfit >= 0 ? '+' : ''}${Formats.money(todayProfit, holding.currency)}',
                size: 12,
              ),
          ],
        ),
      ),
    );
  }
}
