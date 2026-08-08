import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../domain/portfolio_calculator.dart';
import '../../services/snapshot_service.dart';
import 'portfolio_widgets.dart';

final snapshotServiceProvider = Provider<SnapshotService>(
  (ref) => SnapshotService(ref.watch(daoProvider)),
);

final _summaryProvider = FutureProvider<PortfolioSummary>((ref) async {
  final dao = ref.watch(daoProvider);
  final holdings = await ref.watch(holdingsProvider.future);
  final symbols = holdings
      .map((h) => h.symbol)
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .toList();
  final cache = await dao.getCachedPrices(symbols);
  final prev = <String, double>{
    for (final entry in cache.entries)
      if (entry.value.prevClose != null) entry.key: entry.value.prevClose!,
  };
  return const PortfolioCalculator().compute(holdings, prevPriceBySymbol: prev);
});

class PortfolioPage extends ConsumerStatefulWidget {
  const PortfolioPage({super.key});

  @override
  ConsumerState<PortfolioPage> createState() => _PortfolioPageState();
}

class _PortfolioPageState extends ConsumerState<PortfolioPage> {
  final _refreshing = ValueNotifier<bool>(false);
  bool _backfillStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshPrices(showSnack: false);
      _backfillHistory();
    });
  }

  @override
  void dispose() {
    _refreshing.dispose();
    super.dispose();
  }

  /// Backfills the net worth chart from the purchase dates, once per app run.
  Future<void> _backfillHistory() async {
    if (_backfillStarted) return;
    _backfillStarted = true;
    final result = await ref.read(historyBackfillServiceProvider).backfill();
    if (!mounted) return;
    if (result.ok && result.days > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message ?? '历史净值已回填')),
      );
    }
  }

  Future<void> _refreshPrices({bool showSnack = true}) async {
    if (_refreshing.value) return;
    _refreshing.value = true;
    final result = await ref.read(marketServiceProvider).refreshAll();
    await ref.read(snapshotServiceProvider).ensureTodaySnapshot(force: true);
    _refreshing.value = false;
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

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(_summaryProvider);
    final holdings = ref.watch(holdingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('总览'),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: _refreshing,
            builder: (context, refreshing, _) => IconButton(
              tooltip: '刷新行情',
              onPressed: refreshing ? null : _refreshPrices,
              icon: refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ),
        ],
      ),
      body: holdings.when(
        data: (list) => list.isEmpty
            ? _EmptyPortfolio(onRefresh: _refreshPrices)
            : ResponsiveShell(
                child: summary.when(
                  data: (s) => ListView(
                    children: [
                      _SummaryHeader(summary: s),
                      const SizedBox(height: 16),
                      // On phone: allocation above net worth curve.
                      // On tablet/desktop: side by side, curve on the right
                      // filling the remaining width so cards align with the
                      // header above.
                      if (Responsive.isPhone(context))
                        Column(
                          children: [
                            AllocationCard(summary: s),
                            const SizedBox(height: 16),
                            NetWorthChart(),
                          ],
                        )
                      else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 2,
                              child: AllocationCard(summary: s),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 3,
                              child: NetWorthChart(),
                            ),
                          ],
                        ),
                    ],
                  ),
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('计算失败: $e')),
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.summary});

  final PortfolioSummary summary;

  @override
  Widget build(BuildContext context) {
    final netWorth = summary.netWorth;
    final changeColor = context.changeColor(summary.todayChange);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('净资产', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              '¥${Formats.amount(netWorth)}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _Chip(
                  label: '今日 ${summary.todayChangePct == null ? '--' : Formats.pct(summary.todayChangePct!)}',
                  value: '${summary.todayChange >= 0 ? '+' : ''}¥${Formats.amount(summary.todayChange)}',
                  color: changeColor,
                ),
                _Chip(
                  label: '累计收益 ${Formats.pct(summary.profitPct)}',
                  value: '${summary.profit >= 0 ? '+' : ''}¥${Formats.amount(summary.profit)}',
                  color: context.changeColor(summary.profit),
                ),
                if (summary.totalLiabilities > 0)
                  _Chip(
                    label: '负债',
                    value: '¥${Formats.amount(summary.totalLiabilities)}',
                    color: Theme.of(context).colorScheme.outline,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 6),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
        ),
      ],
    );
  }
}

class _EmptyPortfolio extends StatelessWidget {
  const _EmptyPortfolio({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.donut_large_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          const Text('还没有持仓数据\n去"持仓"页添加你的第一笔资产吧', textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
