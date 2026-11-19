import 'dart:async';

import 'package:flutter/material.dart' hide DataRow;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/market_session.dart';
import '../../../core/responsive.dart';
import '../../../core/symbols.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../../domain/holding_category.dart';
import '../../../domain/holding_cost.dart';
import '../../../domain/trade_stats.dart';
import '../../components/app_bar_actions.dart';
import '../../components/data_row.dart';
import '../../components/delta_text.dart';
import '../../components/empty_state.dart';
import '../../components/error_state.dart';
import '../../components/key_shortcuts.dart';
import '../../components/status_chip.dart';
import '../../components/terminal_card.dart';
import '../../components/terminal_fab.dart';
import '../../tokens.dart';
import 'holding_dialogs.dart';
import 'holding_menu.dart';
import 'holdings_table.dart';
import 'open_holding_details.dart';

final _refreshingProvider = StateProvider<bool>((ref) => false);

/// Sort modes for the holdings list. Every table column has an asc/desc
/// pair so header clicks can toggle a direction.
enum HoldingSort {
  defaultOrder('默认'),
  amountDesc('市值折合人民币从高到低'),
  amountAsc('市值折合人民币从低到高'),
  nameAsc('名称 A-Z'),
  nameDesc('名称 Z-A'),
  symbolAsc('代码 A-Z'),
  symbolDesc('代码 Z-A'),
  quantityDesc('数量从高到低'),
  quantityAsc('数量从低到高'),
  costDesc('成本单价从高到低'),
  costAsc('成本单价从低到高'),
  priceDesc('最新价从高到低'),
  priceAsc('最新价从低到高'),
  profitDesc('盈亏折合人民币从高到低'),
  profitAsc('盈亏折合人民币从低到高');

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

/// Total cost in the holding's own currency (same basis as market value).
double _holdingCost(HoldingRow h) {
  final type = AssetType.fromStorage(h.assetType);
  return type.isAmountBased ? effectiveCostOf(h) : h.quantity * h.costPrice;
}

/// Today's profit in the quote currency, adjusted for intraday trades.
///
/// Returns null when the quote is missing, when the cache was not written
/// today, or when the quote's `change` still describes an earlier session
/// for [source] (see `quoteChangeIsToday`) — a quote fetched on a weekend
/// or before the open carries the previous session's move, and showing it
/// as today's double-counts that session.
double? todayProfitOf(
  PriceCacheRow? row,
  double quantity, {
  DateTime? now,
  MarketSource? source,
  Iterable<TransactionRow>? transactions,
  int? holdingId,
}) {
  if (row == null || row.change == null) return null;
  final n = now ?? DateTime.now();
  if (!quoteObservationIsToday(
    n, fetchedAt: row.fetchedAt, quoteDate: row.quoteDate, source: source,
  )) {
    return null;
  }
  if (transactions == null) return row.change! * quantity;
  if (!quantity.isFinite ||
      quantity < 0 ||
      !row.price.isFinite ||
      row.price <= 0) {
    return null;
  }
  final previousClose = row.prevClose ?? row.price - row.change!;
  if (!previousClose.isFinite || previousClose <= 0) return null;
  final trades = <TransactionRow>[];
  var openingQuantity = quantity;
  for (final transaction in transactions) {
    if (holdingId != null && transaction.holdingId != holdingId) continue;
    if (!_isSameDay(transaction.occurredAt.toLocal(), n)) continue;
    final type = TransactionType.fromStorage(transaction.type);
    if (type == TransactionType.split ||
        type == TransactionType.transferIn ||
        type == TransactionType.transferOut) {
      return null;
    }
    if (type != TransactionType.buy && type != TransactionType.sell) continue;
    final tradedQuantity = transaction.quantity;
    final tradedPrice = transaction.price;
    if (tradedQuantity == null ||
        !tradedQuantity.isFinite ||
        tradedQuantity <= 0 ||
        tradedPrice == null ||
        !tradedPrice.isFinite ||
        tradedPrice <= 0 ||
        transaction.currency.toUpperCase() != row.currency.toUpperCase() ||
        transaction.occurredAt.isAfter(row.fetchedAt)) {
      return null;
    }
    openingQuantity += type == TransactionType.buy
        ? -tradedQuantity
        : tradedQuantity;
    trades.add(transaction);
  }
  const epsilon = 0.00000001;
  if (openingQuantity < -epsilon) return null;
  trades.sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
  var runningQuantity = openingQuantity;
  var result = quantity * row.change!;
  for (final transaction in trades) {
    final tradedQuantity = transaction.quantity!;
    final tradedPrice = transaction.price!;
    if (transaction.type == TransactionType.buy.storageName) {
      runningQuantity += tradedQuantity;
      result += tradedQuantity * (previousClose - tradedPrice);
    } else {
      runningQuantity -= tradedQuantity;
      if (runningQuantity < -epsilon) return null;
      result += tradedQuantity * (tradedPrice - previousClose);
    }
  }
  return result;
}

/// Today's change percentage (fraction) from the cached quote, or null.
double? todayChangePctOf(
  PriceCacheRow? row, {
  DateTime? now,
  MarketSource? source,
}) {
  if (row == null || row.changePct == null) return null;
  final n = now ?? DateTime.now();
  if (!quoteObservationIsToday(
    n, fetchedAt: row.fetchedAt, quoteDate: row.quoteDate, source: source,
  )) {
    return null;
  }
  return row.changePct;
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// CNY-converted market value of non-liability holdings.
double assetTotalOf(List<HoldingRow> holdings, Map<String, double> rates) {
  return holdings.fold(0.0, (sum, h) {
    final type = AssetType.fromStorage(h.assetType);
    if (type == AssetType.liability) return sum;
    final rate = valueRateOfOrNull(h, rates);
    if (rate == null) return sum;
    return sum +
        (type.isAmountBased ? h.quantity : h.quantity * h.latestPrice) * rate;
  });
}

/// CNY-converted total outstanding balance of liability holdings.
double liabilityTotalOf(List<HoldingRow> holdings, Map<String, double> rates) {
  return holdings.fold(0.0, (sum, h) {
    if (AssetType.fromStorage(h.assetType) != AssetType.liability) return sum;
    final rate = valueRateOfOrNull(h, rates);
    if (rate == null) return sum;
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
  HoldingSort _assetSort = HoldingSort.defaultOrder;
  HoldingSort _liabilitySort = HoldingSort.defaultOrder;
  HoldingFilter _filter = HoldingFilter.all;
  final _searchFocus = FocusNode();
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _query = widget.initialQuery!;
      _searchCtrl.text = _query;
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
    _searchFocus.dispose();
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

  /// Search match: name, symbol, the asset-type label, or the high-level
  /// category (e.g. tapping "基金" in the allocation card filters to every
  /// fund-type holding — etf + 场外基金). The category match uses the
  /// holding's *effective* category, so a 黄金ETF filed under 黄金 is found
  /// by tapping 黄金 as well as by its own 场内基金 label.
  ///
  /// Liabilities are excluded from the category arm: [AssetType.category]
  /// maps a liability to 现金, and the allocation breakdown skips liabilities
  /// outright (portfolio_calculator), so without this guard a "现金" search
  /// would pull in every liability the category views never count.
  bool _matchesQuery(HoldingRow h, String q) {
    final type = AssetType.fromStorage(h.assetType);
    final cat = AssetCategory.values
        .where((c) => c.label == q || c.storageName == q)
        .firstOrNull;
    if (cat != null &&
        type != AssetType.liability &&
        effectiveCategoryOf(h) == cat) {
      return true;
    }
    return h.name.toLowerCase().contains(q) ||
        (h.symbol ?? '').toLowerCase().contains(q) ||
        type.label.toLowerCase().contains(q) ||
        type.storageName.toLowerCase().contains(q);
  }

  bool get _isAssets => _section == HoldingSection.assets;

  HoldingSort get _sort => _isAssets ? _assetSort : _liabilitySort;

  void _setSort(HoldingSort sort) => setState(() {
    if (_isAssets) {
      _assetSort = sort;
    } else {
      _liabilitySort = sort;
    }
  });

  List<HoldingRow> _sorted(List<HoldingRow> list, Map<String, double> rates) {
    list = list
        .where(
          (h) =>
              (AssetType.fromStorage(h.assetType) != AssetType.liability) ==
              _isAssets,
        )
        .toList();
    final q = _query.trim().toLowerCase();
    var filtered = q.isEmpty
        ? [...list]
        : list.where((h) => _matchesQuery(h, q)).toList();
    filtered = filtered.where(_matchesFilter).toList();
    double? converted(HoldingRow h, double value) {
      final rate = valueRateOfOrNull(h, rates);
      return rate == null ? null : value * rate;
    }

    int compareValues(double? a, double? b, {required bool descending}) {
      if (a == null) return b == null ? 0 : 1;
      if (b == null) return -1;
      return descending ? b.compareTo(a) : a.compareTo(b);
    }

    double? profit(HoldingRow h) {
      var value = _holdingMarketValue(h) - _holdingCost(h);
      if (isHoldingClosed(h) &&
          AssetType.fromStorage(h.assetType) != AssetType.liability) {
        final txns =
            ref.watch(transactionsByHoldingProvider(h.id)).valueOrNull ??
            const <TransactionRow>[];
        final amountBased = AssetType.fromStorage(h.assetType).isAmountBased;
        value =
            TradeStatsCalculator.realizedProfitByHolding(txns, {
              h.id: h.costPrice,
            }, amountBasedHoldingIds: amountBased ? {h.id} : const {})[h.id] ??
            0;
      }
      return converted(h, value);
    }

    final profitValues = <int, double?>{};
    if (_sort == HoldingSort.profitDesc || _sort == HoldingSort.profitAsc) {
      for (final holding in filtered) {
        profitValues[holding.id] = profit(holding);
      }
    }

    switch (_sort) {
      case HoldingSort.defaultOrder:
        if (!_isAssets) {
          return filtered..sort((a, b) => b.quantity.compareTo(a.quantity));
        }
        // Active holdings keep their database order; fully exited ones sink
        // to the bottom, most recently touched first.
        final active = filtered.where((h) => !isHoldingClosed(h)).toList();
        final closed = filtered.where(isHoldingClosed).toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return [...active, ...closed];
      case HoldingSort.amountDesc:
        filtered.sort(
          (a, b) => compareValues(
            converted(a, _holdingMarketValue(a)),
            converted(b, _holdingMarketValue(b)),
            descending: true,
          ),
        );
      case HoldingSort.amountAsc:
        filtered.sort(
          (a, b) => compareValues(
            converted(a, _holdingMarketValue(a)),
            converted(b, _holdingMarketValue(b)),
            descending: false,
          ),
        );
      case HoldingSort.nameAsc:
        filtered.sort((a, b) => a.name.compareTo(b.name));
      case HoldingSort.nameDesc:
        filtered.sort((a, b) => b.name.compareTo(a.name));
      case HoldingSort.symbolAsc:
        filtered.sort((a, b) => (a.symbol ?? '').compareTo(b.symbol ?? ''));
      case HoldingSort.symbolDesc:
        filtered.sort((a, b) => (b.symbol ?? '').compareTo(a.symbol ?? ''));
      case HoldingSort.quantityDesc:
        filtered.sort((a, b) => b.quantity.compareTo(a.quantity));
      case HoldingSort.quantityAsc:
        filtered.sort((a, b) => a.quantity.compareTo(b.quantity));
      case HoldingSort.costDesc:
        filtered.sort(
          (a, b) => compareValues(
            AssetType.fromStorage(a.assetType).isAmountBased
                ? null
                : a.costPrice,
            AssetType.fromStorage(b.assetType).isAmountBased
                ? null
                : b.costPrice,
            descending: true,
          ),
        );
      case HoldingSort.costAsc:
        filtered.sort(
          (a, b) => compareValues(
            AssetType.fromStorage(a.assetType).isAmountBased
                ? null
                : a.costPrice,
            AssetType.fromStorage(b.assetType).isAmountBased
                ? null
                : b.costPrice,
            descending: false,
          ),
        );
      case HoldingSort.priceDesc:
        filtered.sort((a, b) => b.latestPrice.compareTo(a.latestPrice));
      case HoldingSort.priceAsc:
        filtered.sort((a, b) => a.latestPrice.compareTo(b.latestPrice));
      case HoldingSort.profitDesc:
        filtered.sort(
          (a, b) => compareValues(
            profitValues[a.id],
            profitValues[b.id],
            descending: true,
          ),
        );
      case HoldingSort.profitAsc:
        filtered.sort(
          (a, b) => compareValues(
            profitValues[a.id],
            profitValues[b.id],
            descending: false,
          ),
        );
    }
    return filtered;
  }

  void _clearSearch() => setState(() {
    _searchCtrl.clear();
    _query = '';
  });

  void _resetFilters() => setState(() {
    _searchCtrl.clear();
    _query = '';
    _filter = HoldingFilter.all;
  });

  @override
  Widget build(BuildContext context) {
    final holdings = ref.watch(holdingsProvider);
    final refreshing = ref.watch(_refreshingProvider);
    final desktop = Responsive.isDesktop(context);
    final refreshLabel = refreshing ? '正在刷新行情' : '刷新行情';
    final refreshIcon = refreshing
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.refresh, size: 18);
    final VoidCallback? onRefresh = refreshing ? null : _refresh;
    final addHolding = TerminalFab(
      onPressed: () => showAddHoldingDialog(context, ref),
      icon: Icons.add,
      label: '添加持仓',
    );
    return KeyShortcuts(
      onKeyDown: (key) {
        if (key == LogicalKeyboardKey.keyR) _refresh();
        if (key == LogicalKeyboardKey.slash) _searchFocus.requestFocus();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('持仓'),
          actions: [
            const TerminalAppBarActions(),
            if (desktop)
              TextButton.icon(
                onPressed: onRefresh,
                icon: refreshIcon,
                label: Text(refreshLabel),
              )
            else
              IconButton(
                tooltip: refreshLabel,
                onPressed: onRefresh,
                icon: refreshIcon,
              ),
            if (desktop)
              Padding(
                padding: const EdgeInsets.only(left: T.s2, right: T.s4),
                child: addHolding,
              ),
          ],
        ),
        floatingActionButton: desktop ? null : addHolding,
        body: holdings.when(
          data: (list) => list.isEmpty
              ? const EmptyState(message: '还没有持仓，可先添加一项资产或负债。')
              : _buildList(list, desktop),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(
            message: '持仓数据加载失败，请重试',
            onRetry: () => ref.invalidate(holdingsProvider),
          ),
        ),
      ),
    );
  }

  Widget _buildList(List<HoldingRow> list, bool desktop) {
    final rates = ref.watch(cnyRatesProvider).value ?? const <String, double>{};
    final visible = _sorted(list, rates);
    final hide = ref.watch(hideAmountsProvider);
    final total = _isAssets
        ? assetTotalOf(visible, rates)
        : liabilityTotalOf(visible, rates);
    final missing = {
      for (final h in visible)
        if (h.quantity != 0 && valueRateOfOrNull(h, rates) == null)
          h.currency.toUpperCase(),
    }.toList()..sort();
    final hasFilters = _filter != HoldingFilter.all || _query.trim().isNotEmpty;
    final empty = EmptyState(
      message: hasFilters ? '没有符合条件的持仓' : (_isAssets ? '暂无资产' : '暂无负债'),
      action: hasFilters
          ? OutlinedButton(onPressed: _resetFilters, child: const Text('清除筛选'))
          : null,
    );
    final summary = Row(
      children: [
        Text('${visible.length} 项', style: T.label(size: 12)),
        const SizedBox(width: T.s2),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(missing.isEmpty ? '合计' : '已折算合计', style: T.label(size: 12)),
              const SizedBox(width: T.s2),
              Flexible(
                child: Text(
                  hide ? Formats.masked() : Formats.money(total),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.mono(size: 13, weight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return ResponsiveShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildControls(desktop),
          const SizedBox(height: T.s3),
          summary,
          if (missing.isNotEmpty)
            Text(
              '缺少 ${missing.join('、')} 汇率',
              style: T.label(color: T.warning),
            ),
          const SizedBox(height: T.s2),
          Expanded(
            child: desktop
                ? (visible.isEmpty
                      ? empty
                      : HoldingsTable(
                          section: _section,
                          rows: visible,
                          sort: _sort,
                          onSortChanged: _setSort,
                          onHoldingTap: _openHolding,
                          onHoldingMenu: (h, at) =>
                              showHoldingMenu(context, ref, h, at: at),
                        ))
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 60),
                      itemCount: visible.isEmpty ? 1 : visible.length,
                      itemBuilder: (_, index) {
                        if (visible.isEmpty) return empty;
                        final h = visible[index];
                        return _HoldingRowCard(
                          key: ValueKey(h.id),
                          holding: h,
                          onTap: () => _openHolding(h),
                          onMenu: (at) =>
                              showHoldingMenu(context, ref, h, at: at),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _openHolding(HoldingRow holding) => openHoldingDetails(context, holding.id);

  Widget _buildControls(bool desktop) {
    final sections = SegmentedButton<HoldingSection>(
      segments: const [
        ButtonSegment(value: HoldingSection.assets, label: Text('资产')),
        ButtonSegment(value: HoldingSection.liabilities, label: Text('负债')),
      ],
      selected: {_section},
      onSelectionChanged: (s) => setState(() => _section = s.first),
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rInput),
        ),
        side: const BorderSide(color: T.border),
        minimumSize: Size(72, desktop ? 36 : 44),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: T.text2,
        backgroundColor: T.surface,
        selectedForegroundColor: T.text1,
        selectedBackgroundColor: T.surface2,
      ),
    );
    final search = TextField(
      controller: _searchCtrl,
      focusNode: _searchFocus,
      onChanged: (v) => setState(() => _query = v),
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: '搜索名称/代码/类型',
        prefixIcon: const Icon(Icons.search, size: 17),
        prefixIconConstraints: const BoxConstraints(minWidth: 36),
        suffixIconConstraints: BoxConstraints(
          minWidth: desktop ? 36 : 44,
          minHeight: desktop ? 36 : 44,
        ),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: '清空搜索',
                icon: const Icon(Icons.close, size: 16),
                onPressed: () {
                  _clearSearch();
                  _searchFocus.requestFocus();
                },
              ),
        isDense: true,
        constraints: BoxConstraints(minHeight: desktop ? 36 : 44),
        contentPadding: EdgeInsets.symmetric(vertical: desktop ? 9 : 13),
      ),
    );
    final filter = _HoldingsMenu<HoldingFilter>(
      label: '筛选',
      value: _filter,
      values: HoldingFilter.values,
      labelFor: (value) => value.label,
      onSelected: (f) => setState(() => _filter = f),
      active: _filter != HoldingFilter.all,
      desktop: desktop,
    );
    final sort = _HoldingsMenu<HoldingSort>(
      label: '排序',
      value: _sort,
      values: _isAssets
          ? HoldingSort.values
          : const [
              HoldingSort.defaultOrder,
              HoldingSort.amountDesc,
              HoldingSort.amountAsc,
              HoldingSort.nameAsc,
              HoldingSort.nameDesc,
            ],
      labelFor: (value) {
        if (_isAssets) return value.label;
        return switch (value) {
          HoldingSort.amountDesc => '余额折合人民币从高到低',
          HoldingSort.amountAsc => '余额折合人民币从低到高',
          _ => value.label,
        };
      },
      onSelected: _setSort,
      active: _sort != HoldingSort.defaultOrder,
      desktop: desktop,
    );
    if (desktop) {
      return Row(
        children: [
          sections,
          const SizedBox(width: T.s3),
          Expanded(child: search),
          const SizedBox(width: T.s2),
          SizedBox(width: 156, child: filter),
          const SizedBox(width: T.s2),
          SizedBox(width: 174, child: sort),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        search,
        const SizedBox(height: T.s2),
        sections,
        const SizedBox(height: T.s2),
        Row(
          children: [
            Expanded(child: filter),
            const SizedBox(width: T.s2),
            Expanded(child: sort),
          ],
        ),
      ],
    );
  }

  Future<void> _refresh({bool showSnack = true}) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final refreshing = container.read(_refreshingProvider.notifier);
    if (refreshing.state) return;
    refreshing.state = true;
    String message;
    try {
      final result = await container.read(marketServiceProvider).refreshAll();
      if (!refreshing.mounted) return;
      container.invalidate(cnyRatesProvider);
      container.invalidate(priceCacheProvider);
      unawaited(
        container.read(alertNotificationServiceProvider).checkAndNotify(),
      );
      message = switch ((result.updated, result.failed)) {
        (0, 0) => '暂无可更新的行情',
        (final count, 0) => '已更新 $count 项行情',
        (final count, final failed) => '更新 $count 项行情，失败 $failed 项',
      };
    } catch (_) {
      message = '行情刷新失败，请稍后重试';
    } finally {
      if (refreshing.mounted) refreshing.state = false;
    }
    if (mounted && showSnack) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _HoldingsMenu<TValue> extends StatelessWidget {
  const _HoldingsMenu({
    required this.label,
    required this.value,
    required this.values,
    required this.labelFor,
    required this.onSelected,
    required this.active,
    required this.desktop,
  });

  final String label;
  final TValue value;
  final List<TValue> values;
  final String Function(TValue) labelFor;
  final ValueChanged<TValue> onSelected;
  final bool active;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: T.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.rInput),
        side: const BorderSide(color: T.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: PopupMenuButton<TValue>(
        tooltip: label,
        position: PopupMenuPosition.under,
        initialValue: value,
        onSelected: onSelected,
        itemBuilder: (_) => [
          for (final item in values)
            CheckedPopupMenuItem(
              value: item,
              checked: item == value,
              height: desktop ? 38 : 48,
              child: Text(labelFor(item)),
            ),
        ],
        child: Container(
          constraints: BoxConstraints(minHeight: desktop ? 36 : 44),
          padding: const EdgeInsets.symmetric(horizontal: T.s2),
          child: Row(
            children: [
              Text(label, style: T.label(size: 12)),
              const SizedBox(width: T.s2),
              Expanded(
                child: Text(
                  labelFor(value),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.label(size: 12, color: active ? T.accent : T.text1),
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 16, color: T.text2),
            ],
          ),
        ),
      ),
    );
  }
}

class _HoldingRowCard extends ConsumerWidget {
  const _HoldingRowCard({
    super.key,
    required this.holding,
    required this.onTap,
    required this.onMenu,
  });

  final HoldingRow holding;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = AssetType.fromStorage(holding.assetType);
    final marketValue = _holdingMarketValue(holding);
    // Today's change from the price cache (only when written today).
    final cache =
        ref.watch(priceCacheProvider).value ?? const <String, PriceCacheRow>{};
    final todayRow = cachedQuoteForHolding(cache, holding);
    final source = MarketSource.fromStorage(holding.marketSource);
    final transactions = ref
        .watch(transactionsByHoldingProvider(holding.id))
        .valueOrNull;
    final todayProfit = transactions == null
        ? null
        : todayProfitOf(
            todayRow,
            holding.quantity,
            source: source,
            transactions: transactions,
            holdingId: holding.id,
          );
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
    final card = TerminalCard(
      onTap: onTap,
      padding: const EdgeInsets.only(left: T.s3, right: T.s1),
      margin: const EdgeInsets.only(bottom: T.s2),
      child: DataRow(
        title: holding.name,
        titleSuffix: closed
            ? StatusChip(closedHoldingLabel(holding))
            : (holding.archived ? const StatusChip('已归档') : null),
        dimmed: closed || holding.archived,
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: T.label(size: 11, color: T.text3),
        ),
        leading: Icon(type.icon, size: 16, color: type.color),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 128),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      hide
                          ? '****'
                          : Formats.money(marketValue, holding.currency),
                      style: T.mono(
                        size: 14,
                        color: type == AssetType.liability ? T.down : T.text1,
                      ),
                    ),
                  ),
                  if (todayProfit == null)
                    Text('今日 --', style: T.mono(size: 12, color: T.text3))
                  else
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: DeltaText(
                        value: todayProfit,
                        text: hide
                            ? '今日 ****'
                            : '今日 ${todayProfit >= 0 ? '+' : ''}${Formats.money(todayProfit, holding.currency)}',
                        size: 12,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: T.s1),
            HoldingActionsButton(onPressed: onMenu),
          ],
        ),
      ),
    );
    return GestureDetector(
      onLongPressStart: (details) => onMenu(details.globalPosition),
      child: card,
    );
  }
}
