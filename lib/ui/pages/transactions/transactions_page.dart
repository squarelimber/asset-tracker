import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../data/database.dart';
import '../../../domain/trade_stats.dart';
import '../../../services/csv_export.dart';
import '../../../services/file_export.dart';
import '../../components/app_bar_actions.dart';
import '../../components/error_state.dart';
import '../../components/form_fields.dart';
import '../../components/secondary_page_back_button.dart';
import '../../components/terminal_card.dart';
import '../../components/transaction_presentation.dart';
import '../../components/transaction_tile.dart';
import '../../tokens.dart';

/// Unified transaction history across all accounts and holdings, with
/// type / account / date / keyword filters, a cash-flow summary and CSV
/// export of the filtered list.
class TransactionsPage extends ConsumerStatefulWidget {
  const TransactionsPage({
    super.key,
    this.initialDate,
    this.initialTransactionId,
  });

  final String? initialDate;
  final int? initialTransactionId;

  @override
  ConsumerState<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends ConsumerState<TransactionsPage> {
  TransactionType? _typeFilter;
  bool _repaymentsOnly = false;
  String? _relatedDate;
  int? _relatedId;
  int? _accountFilter;
  String _datePreset = 'all'; // all | month | 3m | year
  final _keywordCtrl = TextEditingController();
  bool _exporting = false;

  bool get _hasFilters =>
      _typeFilter != null ||
      _repaymentsOnly ||
      _relatedDate != null ||
      _relatedId != null ||
      _accountFilter != null ||
      _datePreset != 'all' ||
      _keywordCtrl.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _relatedDate = widget.initialDate;
    _relatedId = widget.initialTransactionId;
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    super.dispose();
  }

  bool _inDateRange(DateTime at) {
    final now = DateTime.now();
    return switch (_datePreset) {
      'month' => at.year == now.year && at.month == now.month,
      '3m' => at.isAfter(now.subtract(const Duration(days: 90))),
      'year' => at.year == now.year,
      _ => true,
    };
  }

  List<TransactionRow> _filter(
    List<TransactionRow> txns,
    Map<int, HoldingRow> holdingsById,
    Map<int, String> accountName,
  ) {
    final kw = _keywordCtrl.text.trim().toLowerCase();
    final redemptionGroups = <String, List<TransactionRow>>{};
    for (final txn in txns) {
      if (txn.redemptionGroup case final group?) {
        (redemptionGroups[group] ??= []).add(txn);
      }
    }
    return txns.where((t) {
      final type = TransactionType.fromStorage(t.type);
      if (_typeFilter != null && type != _typeFilter) return false;
      final repayment = repaymentOf(
        t,
        holdingsById[t.cashSourceId],
        holdingsById[t.cashTargetId],
      );
      if (_repaymentsOnly && repayment == null) return false;
      final related = [
        holdingsById[t.holdingId],
        holdingsById[t.cashSourceId],
        holdingsById[t.cashTargetId],
        for (final leg
            in redemptionGroups[t.redemptionGroup] ?? const <TransactionRow>[])
          holdingsById[leg.holdingId],
      ].whereType<HoldingRow>();
      final accountIds = {t.accountId, ...related.map((h) => h.accountId)};
      if (_accountFilter != null && !accountIds.contains(_accountFilter)) {
        return false;
      }
      final day = t.occurredAt.toLocal();
      if (!_inDateRange(day) ||
          (_relatedId != null && t.id != _relatedId) ||
          (_relatedId == null &&
              _relatedDate != null &&
              todayKey(day) != _relatedDate)) {
        return false;
      }
      if (kw.isNotEmpty) {
        final terms = [
          for (final holding in related) ...[
            holding.name,
            holding.symbol ?? '',
          ],
          for (final id in accountIds) accountName[id] ?? '',
          t.note ?? '',
          repayment?.label ?? type.label,
        ].join(' ').toLowerCase();
        if (!terms.contains(kw)) return false;
      }
      return true;
    }).toList();
  }

  /// Counterparty line for the tile, e.g. "扣款来源：天天宝".
  String? _counterpartyText(
    TransactionRow t,
    Map<int, HoldingRow> holdingsById,
  ) {
    String name(int? id) => id == null ? '' : (holdingsById[id]?.name ?? '');
    final type = TransactionType.fromStorage(t.type);
    return switch (type) {
      TransactionType.buy =>
        t.cashSourceId == null ? null : '扣款来源：${name(t.cashSourceId)}',
      TransactionType.sell ||
      TransactionType.dividend ||
      TransactionType.income =>
        t.cashTargetId == null ? null : '入账：${name(t.cashTargetId)}',
      TransactionType.expense =>
        t.cashTargetId == null ? null : '扣款：${name(t.cashTargetId)}',
      TransactionType.transferIn =>
        t.cashSourceId == null ? null : '来源：${name(t.cashSourceId)}',
      TransactionType.transferOut =>
        t.cashTargetId == null ? null : '去向：${name(t.cashTargetId)}',
      _ => null,
    };
  }

  /// Unit cost for the tile's per-row realized line. Amount-based holdings
  /// store the cumulative invested amount in costPrice (not a unit price),
  /// so a per-row realized figure is not meaningful for them (it is
  /// exactly 0 by construction) and is omitted.
  double? _tileCostPrice(TransactionRow t, Map<int, HoldingRow> holdingsById) {
    final h = t.holdingId == null ? null : holdingsById[t.holdingId];
    if (h == null) return null;
    return AssetType.fromStorage(h.assetType).isAmountBased
        ? null
        : h.costPrice;
  }

  List<(DateTime, List<TransactionRow>)> _groupByDay(
    List<TransactionRow> txns,
  ) {
    final groups = <DateTime, List<TransactionRow>>{};
    for (final t in txns) {
      final d = t.occurredAt.toLocal();
      groups.putIfAbsent(DateTime(d.year, d.month, d.day), () => []).add(t);
    }
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final k in keys) (k, groups[k]!)];
  }

  Future<void> _exportCsv(
    List<TransactionRow> filtered,
    List<HoldingRow> holdings,
    Map<int, String> accountName,
  ) async {
    if (_exporting || filtered.isEmpty) return;
    setState(() => _exporting = true);
    final content = const CsvExport().transactionsDetailed(filtered, {
      for (final h in holdings) h.id: h.name,
    }, accountName);
    final now = DateTime.now();
    final stamp =
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    try {
      await saveBytesToUser(
        context,
        Uint8List.fromList(utf8.encode(content)),
        fileName: '流水_${todayKey()}-$stamp.csv',
        mime: 'text/csv',
        typeGroup: const XTypeGroup(label: 'CSV', extensions: ['csv']),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _resetFilters() {
    setState(() {
      _typeFilter = null;
      _repaymentsOnly = false;
      _relatedDate = null;
      _relatedId = null;
      _accountFilter = null;
      _datePreset = 'all';
      _keywordCtrl.clear();
    });
  }

  /// 修改一笔流水的发生日期。日期是历史回放（金额型平滑、收益日历、
  /// 月度收益）的分组键，改日期即改写历史 —— 必须全量重建。
  Future<void> _editDate(TransactionRow t) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改流水日期'),
        content: const Text('保存后会重算历史净值。若这笔流水属于同一笔赎回出资，关联的赎回和买入会一起调整日期。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final local = DateUtils.dateOnly(t.occurredAt.toLocal());
    final today = DateUtils.dateOnly(DateTime.now());
    final earliest = DateTime(2020);
    final picked = await showDatePicker(
      context: context,
      initialDate: local.isAfter(today) ? today : local,
      firstDate: local.isBefore(earliest) ? local : earliest,
      lastDate: today,
    );
    if (picked == null || picked == local || !mounted) return;
    final result = await ref
        .read(transactionServiceProvider)
        .reschedule(t.id, picked);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message ?? '流水日期已更新')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final txns = ref.watch(transactionsProvider);
    final holdings = ref.watch(holdingsProvider).value ?? const <HoldingRow>[];
    final accounts = ref.watch(accountsProvider).value ?? const <AccountRow>[];
    final rates =
        ref.watch(transactionCnyRatesProvider).value ??
        ref.watch(cnyRatesProvider).value ??
        const <String, double>{};
    final holdingsById = {for (final h in holdings) h.id: h};
    final accountName = {for (final a in accounts) a.id: a.name};
    final filtered = _filter(
      txns.valueOrNull ?? const [],
      holdingsById,
      accountName,
    );
    final exportAction = _exporting || filtered.isEmpty
        ? null
        : () => _exportCsv(filtered, holdings, accountName);
    final isPhone = Responsive.isPhone(context);
    final hideAmounts = ref.watch(hideAmountsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const SecondaryPageBackButton(),
        title: const Text('交易流水'),
        actions: [
          IconButton(
            tooltip: hideAmounts ? '显示金额' : '隐藏金额',
            isSelected: hideAmounts,
            icon: const Icon(Icons.visibility_outlined, size: 18),
            selectedIcon: const Icon(Icons.visibility_off_outlined, size: 18),
            onPressed: () =>
                ref.read(hideAmountsProvider.notifier).state = !hideAmounts,
          ),
          IconButton(
            tooltip: _exporting ? '正在导出' : '导出 CSV（当前筛选）',
            icon: _exporting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download_outlined),
            onPressed: exportAction,
          ),
          const TerminalAppBarActions(),
        ],
      ),
      body: txns.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(
          message: '流水加载失败，请重试',
          onRetry: () => ref.invalidate(transactionsProvider),
        ),
        data: (all) {
          const calculator = TradeStatsCalculator();
          final stats = calculator.compute(
            filtered,
            const [],
            cnyRates: rates,
            requireFxRates: true,
          );
          return SingleChildScrollView(
            child: ResponsiveShell(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final opt in <(TransactionType?, String)>[
                          (null, '全部'),
                          (null, '还款'),
                          for (final t in TransactionType.values) (t, t.label),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(opt.$2),
                              selected: _typeSelected(opt),
                              onSelected: (_) => setState(() {
                                _repaymentsOnly = opt.$2 == '还款';
                                _typeFilter = opt.$1;
                              }),
                              showCheckmark: false,
                              selectedColor: T.surface2,
                              backgroundColor: T.surface,
                              side: BorderSide(
                                color: _typeSelected(opt) ? T.accent : T.border,
                              ),
                              labelStyle: TextStyle(
                                fontSize: 12,
                                color: _typeSelected(opt) ? T.text1 : T.text2,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: T.s3),
                  if (isPhone) ...[
                    _searchField(),
                    const SizedBox(height: T.s3),
                  ],
                  Row(
                    children: [
                      Flexible(
                        child: DropdownButtonFormField<int?>(
                          initialValue: _accountFilter,
                          isExpanded: true,
                          decoration: terminalDecoration('账户'),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('全部账户'),
                            ),
                            for (final a in accounts)
                              DropdownMenuItem(
                                value: a.id,
                                child: Text(
                                  a.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() => _accountFilter = v),
                        ),
                      ),
                      const SizedBox(width: T.s3),
                      Flexible(
                        child: DropdownButtonFormField<String>(
                          initialValue: _datePreset,
                          isExpanded: true,
                          decoration: terminalDecoration('时间'),
                          items: const [
                            DropdownMenuItem(value: 'all', child: Text('全部')),
                            DropdownMenuItem(value: 'month', child: Text('本月')),
                            DropdownMenuItem(value: '3m', child: Text('近3月')),
                            DropdownMenuItem(value: 'year', child: Text('今年')),
                          ],
                          onChanged: (v) =>
                              setState(() => _datePreset = v ?? 'all'),
                        ),
                      ),
                      if (!isPhone) ...[
                        const SizedBox(width: T.s3),
                        Expanded(flex: 2, child: _searchField()),
                      ],
                    ],
                  ),
                  if (_relatedDate case final date?)
                    Padding(
                      padding: const EdgeInsets.only(top: T.s2),
                      child: Text(
                        _relatedId == null ? '关联日期 $date' : '$date 的关联流水',
                        style: T.label(),
                      ),
                    ),
                  if (_hasFilters)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _resetFilters,
                        child: const Text('清除筛选'),
                      ),
                    ),
                  const SizedBox(height: T.s4),
                  _SummaryCard(stats: stats, count: filtered.length),
                  const SizedBox(height: T.s4),
                  if (filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          all.isEmpty ? '暂无交易流水' : '没有符合条件的流水',
                          style: const TextStyle(color: T.text2, fontSize: 13),
                        ),
                      ),
                    )
                  else
                    for (final (day, rows) in _groupByDay(filtered)) ...[
                      _DayHeader(
                        day: day,
                        stats: calculator.compute(
                          rows,
                          const [],
                          cnyRates: rates,
                          requireFxRates: true,
                        ),
                      ),
                      for (final t in rows)
                        _transactionRow(t, holdingsById, accountName),
                    ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _transactionRow(
    TransactionRow t,
    Map<int, HoldingRow> holdingsById,
    Map<int, String> accountNames,
  ) {
    final repayment = repaymentOf(
      t,
      holdingsById[t.cashSourceId],
      holdingsById[t.cashTargetId],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TransactionTile(
        txn: t,
        costPrice: _tileCostPrice(t, holdingsById),
        holdingName: holdingsById[t.holdingId]?.name,
        accountName: accountNames[t.accountId],
        repaymentLabel: repayment?.label,
        counterpartyText: repayment == null
            ? _counterpartyText(t, holdingsById)
            : '资金来源：${repayment.source.name} · 还款账户：${repayment.target.name}',
        onEditDate: () => _editDate(t),
      ),
    );
  }

  bool _typeSelected((TransactionType?, String) option) => _repaymentsOnly
      ? option.$2 == '还款'
      : option.$2 != '还款' && _typeFilter == option.$1;

  Widget _searchField() => TextField(
    controller: _keywordCtrl,
    onChanged: (_) => setState(() {}),
    decoration: terminalDecoration('搜索产品、账户或备注').copyWith(
      prefixIcon: const Icon(Icons.search, size: 18),
      suffixIcon: _keywordCtrl.text.isEmpty
          ? null
          : IconButton(
              tooltip: '清除搜索',
              onPressed: () => setState(_keywordCtrl.clear),
              icon: const Icon(Icons.close, size: 18),
            ),
    ),
  );
}

class _SummaryCard extends ConsumerWidget {
  const _SummaryCard({required this.stats, required this.count});

  final TradeStats stats;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hide = ref.watch(hideAmountsProvider);
    return TerminalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('汇总（$count 笔）', style: T.label()),
              const Spacer(),
              Text('净现金流', style: T.label()),
              const SizedBox(width: 8),
              Text(
                hide
                    ? '****'
                    : stats.missingCurrencies.isNotEmpty &&
                          stats.monthlyCashflow.isEmpty
                    ? '--'
                    : '${stats.cashflow >= 0 ? '+' : ''}${Formats.money(stats.cashflow)}',
                style: T.mono(
                  size: 13,
                  weight: FontWeight.w700,
                  color: T.changeColor(stats.cashflow),
                ),
              ),
            ],
          ),
          if (stats.missingCurrencies.isNotEmpty) ...[
            const SizedBox(height: T.s2),
            Text(
              '缺少 ${(stats.missingCurrencies.toList()..sort()).join('、')} 汇率，相关流水暂未计入人民币汇总。',
              style: T.label(color: T.warning),
            ),
          ],
          const SizedBox(height: T.s3),
          Wrap(
            spacing: T.s4,
            runSpacing: T.s2,
            children: [
              _StatItem(label: '买入', value: -stats.boughtTotal),
              _StatItem(label: '卖出', value: stats.soldTotal),
              _StatItem(label: '收入', value: stats.incomeTotal),
              _StatItem(label: '支出', value: -stats.expenseTotal),
              _StatItem(label: '分红', value: stats.dividendTotal),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatItem extends ConsumerWidget {
  const _StatItem({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hide = ref.watch(hideAmountsProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: T.label()),
        Text(
          hide ? '****' : '${value >= 0 ? '+' : ''}${Formats.money(value)}',
          style: T.mono(
            size: 12,
            weight: FontWeight.w600,
            color: T.changeColor(value),
          ),
        ),
      ],
    );
  }
}

class _DayHeader extends ConsumerWidget {
  const _DayHeader({required this.day, required this.stats});

  final DateTime day;
  final TradeStats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hide = ref.watch(hideAmountsProvider);
    final now = DateTime.now();
    final net = stats.cashflow;
    final hasMissingRates = stats.missingCurrencies.isNotEmpty;
    final label = hasMissingRates ? '当日已折算' : '当日';
    final amount = hasMissingRates && stats.monthlyCashflow.isEmpty
        ? '--'
        : '${net >= 0 ? '+' : ''}${Formats.money(net)}';
    final isToday =
        day.year == now.year && day.month == now.month && day.day == now.day;
    return Padding(
      padding: const EdgeInsets.only(top: T.s3, bottom: T.s2),
      child: Row(
        children: [
          Text(
            '${Formats.date(day)}${isToday ? ' · 今天' : ''}',
            style: T.mono(size: 12, weight: FontWeight.w600, color: T.text2),
          ),
          const Spacer(),
          Text(
            hide ? '当日 ****' : '$label $amount',
            style: T.mono(
              size: 12,
              weight: FontWeight.w600,
              color: T.changeColor(net),
            ),
          ),
        ],
      ),
    );
  }
}
