import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../ui/components/app_bar_actions.dart';
import '../../ui/tokens.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../domain/trade_stats.dart';

final _statsProvider = FutureProvider<TradeStats>((ref) async {
  final txns = await ref.watch(transactionsProvider.future);
  final holdings = await ref.watch(holdingsProvider.future);
  final rates = await ref.watch(cnyRatesProvider.future);
  return const TradeStatsCalculator().compute(txns, holdings, cnyRates: rates);
});

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(_statsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('统计'),
        actions: [const TerminalAppBarActions()],
      ),
      body: ResponsiveShell(
        child: stats.when(
          data: (s) {
            final months = s.monthlyCashflow.keys.toList()..sort((a, b) => b.compareTo(a));
            return ListView(
              children: [
                ResponsiveGrid(
                  children: [
                    _StatCard(
                      label: '净现金流',
                      value: '${s.cashflow >= 0 ? '+' : ''}¥${Formats.amount(s.cashflow)}',
                      color: context.changeColor(s.cashflow),
                    ),
                    _StatCard(
                      label: '已落袋收益',
                      value:
                          '${s.realizedProfit >= 0 ? '+' : ''}¥${Formats.amount(s.realizedProfit)}',
                      color: context.changeColor(s.realizedProfit),
                    ),
                    _StatCard(
                      label: '累计分红',
                      value: '¥${Formats.amount(s.dividendTotal)}',
                      color: T.up,
                    ),
                    _StatCard(
                      label: '累计买入',
                      value: '¥${Formats.amount(s.boughtTotal)}',
                      color: T.accent,
                    ),
                    _StatCard(
                      label: '累计卖出',
                      value: '¥${Formats.amount(s.soldTotal)}',
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    _StatCard(
                      label: '累计收入',
                      value: '¥${Formats.amount(s.incomeTotal)}',
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    _StatCard(
                      label: '累计支出',
                      value: '¥${Formats.amount(s.expenseTotal)}',
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text('月度现金流', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (months.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('暂无流水数据，先记一笔交易吧')),
                    ),
                  )
                else
                  Card(
                    child: Column(
                      children: [
                        for (final m in months) ...[
                          ListTile(
                            dense: true,
                            title: Text(m),
                            trailing: Text(
                              '${(s.monthlyCashflow[m] ?? 0) >= 0 ? '+' : ''}¥${Formats.amount(s.monthlyCashflow[m] ?? 0)}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: context.changeColor(s.monthlyCashflow[m] ?? 0),
                              ),
                            ),
                          ),
                          if (m != months.last) const Divider(height: 1),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  '已落袋收益为卖出（卖出价 − 当前成本价）× 数量 的估算；'
                  '买入后成本变动时会略有偏差。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载失败: $e')),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
