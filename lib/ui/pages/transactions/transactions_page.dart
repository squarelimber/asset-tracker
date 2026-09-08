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
import '../../components/terminal_card.dart';
import '../../components/transaction_tile.dart';
import '../../tokens.dart';

/// Unified transaction history across all accounts and holdings, with
/// type / account / date / keyword filters, a cash-flow summary and CSV
/// export of the filtered list.
class TransactionsPage extends ConsumerStatefulWidget {
  const TransactionsPage({super.key});

  @override
  ConsumerState<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends ConsumerState<TransactionsPage> {
  TransactionType? _typeFilter;
  int? _accountFilter;
  String _datePreset = 'all'; // all | month | 3m | year
  final _keywordCtrl = TextEditingController();

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
    return txns.where((t) {
      if (_typeFilter != null &&
          TransactionType.fromStorage(t.type) != _typeFilter) {
        return false;
      }
      if (_accountFilter != null && t.accountId != _accountFilter) {
        return false;
      }
      if (!_inDateRange(t.occurredAt.toLocal())) return false;
      if (kw.isNotEmpty) {
        final holding = t.holdingId == null ? null : holdingsById[t.holdingId];
        final haystack = [
          holding?.name ?? '',
          t.note ?? '',
          accountName[t.accountId] ?? '',
        ].join(' ').toLowerCase();
        if (!haystack.contains(kw)) return false;
      }
      return true;
    }).toList();
  }

  /// Counterparty line for the tile, e.g. "扣款来源：天天宝".
  String? _counterpartyText(TransactionRow t, Map<int, HoldingRow> holdingsById) {
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
        t.cashSourceId == null ? null : '扣款：${name(t.cashSourceId)}',
      TransactionType.transferIn =>
        t.cashSourceId == null ? null : '来源：${name(t.cashSourceId)}',
      TransactionType.transferOut =>
        t.cashTargetId == null ? null : '去向：${name(t.cashTargetId)}',
      _ => null,
    };
  }

  double _rateOf(String currency, Map<String, double> rates) {
    final rate = rates[currency.toUpperCase()];
    return (rate == null || rate <= 0) ? 1 : rate;
  }

  double _dayNet(List<TransactionRow> rows, Map<String, double> rates) {
    var net = 0.0;
    for (final t in rows) {
      final sign = switch (TransactionType.fromStorage(t.type)) {
        TransactionType.buy ||
        TransactionType.expense ||
        TransactionType.transferOut =>
          -1.0,
        TransactionType.sell ||
        TransactionType.income ||
        TransactionType.dividend ||
        TransactionType.transferIn =>
          1.0,
        _ => 0.0,
      };
      net += sign * t.amount * _rateOf(t.currency, rates);
    }
    return net;
  }

  List<(DateTime, List<TransactionRow>)> _groupByDay(List<TransactionRow> txns) {
    final groups = <DateTime, List<TransactionRow>>{};
    for (final t in txns) {
      final d = t.occurredAt.toLocal();
      groups.putIfAbsent(DateTime(d.year, d.month, d.day), () => []).add(t);
    }
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final k in keys) (k, groups[k]!)];
  }

  Future<void> _exportCsv() async {
    final txns = ref.read(transactionsProvider).valueOrNull;
    if (txns == null) return;
    final holdings = ref.read(holdingsProvider).value ?? const <HoldingRow>[];
    final accounts =
        ref.read(accountsProvider).value ?? const <AccountRow>[];
    final holdingsById = {for (final h in holdings) h.id: h};
    final accountName = {for (final a in accounts) a.id: a.name};
    final filtered = _filter(txns, holdingsById, accountName);
    final content = const CsvExport().transactionsDetailed(
      filtered,
      {for (final h in holdings) h.id: h.name},
      accountName,
    );
    final now = DateTime.now();
    final stamp =
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    if (!mounted) return;
    await saveBytesToUser(
      context,
      Uint8List.fromList(utf8.encode(content)),
      fileName: '流水_${todayKey()}-$stamp.csv',
      mime: 'text/csv',
      typeGroup: const XTypeGroup(label: 'CSV', extensions: ['csv']),
    );
  }

  @override
  Widget build(BuildContext context) {
    final txns = ref.watch(transactionsProvider);
    final holdings = ref.watch(holdingsProvider).value ?? const <HoldingRow>[];
    final accounts = ref.watch(accountsProvider).value ?? const <AccountRow>[];
    final rates = ref.watch(cnyRatesProvider).value ?? const <String, double>{};

    return Scaffold(
      appBar: AppBar(
        title: const Text('交易流水'),
        actions: [
          IconButton(
            tooltip: '导出 CSV（当前筛选）',
            icon: const Icon(Icons.file_download_outlined, color: T.text2),
            onPressed: _exportCsv,
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
          final holdingsById = {for (final h in holdings) h.id: h};
          final accountName = {for (final a in accounts) a.id: a.name};
          final filtered = _filter(all, holdingsById, accountName);
          final stats = const TradeStatsCalculator().compute(
            filtered,
            holdings,
            cnyRates: rates,
          );
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: Responsive.isPhone(context) ? 16 : 24,
              vertical: 16,
            ),
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
                        for (final t in TransactionType.values) (t, t.label),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(opt.$2),
                            selected: _typeFilter == opt.$1,
                            onSelected: (_) =>
                                setState(() => _typeFilter = opt.$1),
                            showCheckmark: false,
                            selectedColor: T.accent,
                            backgroundColor: T.surface2,
                            side: const BorderSide(color: T.border),
                            labelStyle: TextStyle(
                              fontSize: 12,
                              color: _typeFilter == opt.$1 ? T.bg : T.text2,
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
                Row(
                  children: [
                    SizedBox(
                      width: 136,
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
                        onChanged: (v) =>
                            setState(() => _accountFilter = v),
                      ),
                    ),
                    const SizedBox(width: T.s3),
                    SizedBox(
                      width: 108,
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
                    const SizedBox(width: T.s3),
                    Expanded(
                      child: TerminalTextField(
                        controller: _keywordCtrl,
                        label: '搜索产品 / 备注',
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: T.s4),
                _SummaryCard(stats: stats, count: filtered.length),
                const SizedBox(height: T.s4),
                if (filtered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: Text('没有符合条件的流水',
                          style: TextStyle(color: T.text3, fontSize: 13)),
                    ),
                  )
                else
                  for (final (day, rows) in _groupByDay(filtered)) ...[
                    _DayHeader(
                      day: day,
                      net: _dayNet(rows, rates),
                    ),
                    for (final t in rows) ...[
                      TransactionTile(
                        txn: t,
                        costPrice: t.holdingId == null
                            ? null
                            : holdingsById[t.holdingId]?.costPrice,
                        holdingName: t.holdingId == null
                            ? null
                            : holdingsById[t.holdingId]?.name,
                        accountName: accountName[t.accountId],
                        counterpartyText: _counterpartyText(t, holdingsById),
                      ),
                      const SizedBox(height: 4),
                    ],
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.stats, required this.count});

  final TradeStats stats;
  final int count;

  @override
  Widget build(BuildContext context) {
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
                '${stats.cashflow >= 0 ? '+' : ''}${Formats.money(stats.cashflow)}',
                style: T.mono(
                  size: 13,
                  weight: FontWeight.w700,
                  color: T.changeColor(stats.cashflow),
                ),
              ),
            ],
          ),
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

class _StatItem extends StatelessWidget {
  const _StatItem({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: T.label()),
        Text(
          '${value >= 0 ? '+' : ''}${Formats.money(value)}',
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

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.net});

  final DateTime day;
  final double net;

  @override
  Widget build(BuildContext context) {
    final isToday = day == DateTime.now();
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
            '当日 ${net >= 0 ? '+' : ''}${Formats.money(net)}',
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
