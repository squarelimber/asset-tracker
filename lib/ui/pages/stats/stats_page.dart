import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../data/database.dart';
import '../../../domain/daily_earnings.dart';
import '../../../domain/trade_stats.dart';
import '../../components/app_bar_actions.dart';
import '../../components/error_state.dart';
import '../../components/monthly_profit_chart.dart';
import '../../components/section_header.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

final statsProvider = FutureProvider<TradeStats>((ref) async {
  final txns = await ref.watch(transactionsProvider.future);
  final holdings = await ref.watch(holdingsProvider.future);
  final rates = Map<String, double>.of(
    await ref.watch(cnyRatesProvider.future),
  );
  final missing = txns
      .map((transaction) => transaction.currency.toUpperCase())
      .where((currency) => currency != 'CNY' && (rates[currency] ?? 0) <= 0)
      .toSet();
  if (missing.isNotEmpty) {
    rates.addAll(
      await ref.read(marketServiceProvider).loadCnyRates(missing.toList()),
    );
  }
  return const TradeStatsCalculator().compute(
    txns,
    holdings,
    cnyRates: rates,
    requireFxRates: true,
  );
});

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshots = ref.watch(snapshotsProvider);
    final stats = ref.watch(statsProvider);
    final hide = ref.watch(hideAmountsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('统计'),
        actions: const [TerminalAppBarActions()],
      ),
      body: ResponsiveShell(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(snapshotsProvider);
            ref.invalidate(statsProvider);
            ref.invalidate(cnyRatesProvider);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Wrap(
                spacing: T.s2,
                runSpacing: T.s2,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => context.push('/earnings-calendar'),
                    icon: const Icon(Icons.calendar_month_outlined, size: 18),
                    label: const Text('收益日历'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => context.push('/product-earnings'),
                    icon: const Icon(Icons.table_chart_outlined, size: 18),
                    label: const Text('产品收益日历'),
                  ),
                ],
              ),
              const SizedBox(height: T.s4),
              const SectionHeader(label: '收益概览'),
              snapshots.when(
                data: (list) {
                  final months = _monthlyProfitOf(list);
                  if (months.isEmpty) {
                    return const TerminalCard(
                      child: Text('暂无收益数据，每日打开 App 自动记录净值'),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TerminalCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('月度收益', style: T.label(size: 12)),
                            const SizedBox(height: T.s2),
                            MonthlyProfitChart(
                              months: months,
                              hideAmounts: hide,
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '月度收益根据净值快照计算，转入转出本金不计入。缺少快照的月份显示为无数据；快照不连续时，间隔收益归入下一条快照所在月份。',
                        style: T.label(),
                      ),
                      const SizedBox(height: T.s3),
                      TerminalCard(
                        child: _MonthSummary(months: months, hide: hide),
                      ),
                    ],
                  );
                },
                loading: () => const TerminalCard(
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => TerminalCard(
                  child: ErrorState(
                    message: '收益数据加载失败，请重试',
                    onRetry: () => ref.invalidate(snapshotsProvider),
                  ),
                ),
              ),
              const SizedBox(height: T.s3),
              const SectionHeader(label: '交易流水'),
              stats.when(
                data: (value) => TerminalCard(
                  child: _TradeSummary(stats: value, hide: hide),
                ),
                loading: () => const TerminalCard(
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => TerminalCard(
                  child: ErrorState(
                    message: '交易统计加载失败，请重试',
                    onRetry: () => ref.invalidate(statsProvider),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Map<String, double> _monthlyProfitOf(List<SnapshotRow> snapshots) {
  final earnings = const DailyEarningsCalculator().compute(snapshots);
  final byMonth = <String, double>{};
  for (final day in earnings) {
    final key = day.date.substring(0, 7);
    byMonth[key] = (byMonth[key] ?? 0) + day.profit;
  }
  return byMonth;
}

class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.months, required this.hide});
  final Map<String, double> months;
  final bool hide;

  @override
  Widget build(BuildContext context) {
    var best = months.keys.first;
    var worst = best;
    for (final key in months.keys) {
      if (months[key]! > months[best]!) best = key;
      if (months[key]! < months[worst]!) worst = key;
    }
    final positive = months.values.where((value) => value > 0).length;
    return Column(
      children: [
        _StatLine(label: '最佳月份 $best', value: months[best]!, hide: hide),
        _StatLine(label: '最差月份 $worst', value: months[worst]!, hide: hide),
        _StatLine(
          label: '盈利月份占比',
          text: '${(positive / months.length * 100).toStringAsFixed(0)}%',
        ),
      ],
    );
  }
}

class _TradeSummary extends StatelessWidget {
  const _TradeSummary({required this.stats, required this.hide});
  final TradeStats stats;
  final bool hide;

  @override
  Widget build(BuildContext context) {
    final missing = stats.missingCurrencies.toList()..sort();
    final unavailable = missing.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (unavailable) ...[
          Text(
            '缺少 ${missing.join('、')} 汇率，交易统计待折算。',
            style: T.label(color: T.warning),
          ),
          const SizedBox(height: T.s2),
        ],
        _StatLine(
          label: '净现金流',
          value: stats.cashflow,
          hide: hide,
          unavailable: unavailable,
        ),
        _StatLine(
          label: '已落袋收益（估算）',
          value: stats.realizedProfit,
          hide: hide,
          unavailable: unavailable,
        ),
        _StatLine(
          label: '累计分红',
          value: stats.dividendTotal,
          hide: hide,
          unavailable: unavailable,
        ),
        _StatLine(
          label: '现金支付买入',
          value: stats.boughtTotal,
          hide: hide,
          unavailable: unavailable,
        ),
        _StatLine(
          label: '卖出入账现金',
          value: stats.soldTotal,
          hide: hide,
          unavailable: unavailable,
        ),
        _StatLine(
          label: '累计收入',
          value: stats.incomeTotal,
          hide: hide,
          unavailable: unavailable,
        ),
        _StatLine(
          label: '累计支出',
          value: stats.expenseTotal,
          hide: hide,
          unavailable: unavailable,
        ),
        const SizedBox(height: T.s2),
        Text(
          '金额按当前或缓存汇率折合人民币。净现金流统计相关现金持仓的收支与买卖，不含内部转账。已落袋收益按当前成本估算。',
          style: T.label(),
        ),
      ],
    );
  }
}

class _StatLine extends StatelessWidget {
  const _StatLine({
    required this.label,
    this.value,
    this.text,
    this.hide = false,
    this.unavailable = false,
  });
  final String label;
  final double? value;
  final String? text;
  final bool hide;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final display =
        text ??
        (hide
            ? '****'
            : unavailable
            ? '待折算'
            : Formats.money(value!));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: T.s2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: T.label(size: 12))),
          const SizedBox(width: T.s2),
          Flexible(
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: T.mono(size: 13),
            ),
          ),
        ],
      ),
    );
  }
}
