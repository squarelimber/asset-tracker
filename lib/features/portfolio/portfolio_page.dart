import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../domain/portfolio_calculator.dart';
import '../../services/history_backfill_service.dart';
import '../../services/market/market_service.dart';
import 'portfolio_widgets.dart';

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
  // Convert non-CNY holdings into CNY using the shared FX rates.
  final cnyRates = await ref.watch(cnyRatesProvider.future);
  // Realized gains from sell transactions.
  final sells = (await dao.getTransactions())
      .where((t) => t.type == TransactionType.sell.storageName)
      .toList();
  return const PortfolioCalculator().compute(
    holdings,
    prevPriceBySymbol: prev,
    cnyRates: cnyRates,
    sellTransactions: sells,
  );
});

class PortfolioPage extends ConsumerStatefulWidget {
  const PortfolioPage({super.key});

  @override
  ConsumerState<PortfolioPage> createState() => _PortfolioPageState();
}

class _PortfolioPageState extends ConsumerState<PortfolioPage> {
  final _refreshing = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshPrices(showSnack: false);
    });
  }

  @override
  void dispose() {
    _refreshing.dispose();
    super.dispose();
  }

  Future<void> _refreshPrices({bool showSnack = true}) async {
    if (_refreshing.value) return;
    _refreshing.value = true;
    MarketRefreshResult? result;
    Object? error;
    try {
      result = await ref.read(marketServiceProvider).refreshAll();
      await ref.read(snapshotServiceProvider).ensureTodaySnapshot(force: true);
      // FX rates may have changed with the refresh.
      ref.invalidate(cnyRatesProvider);
    } catch (e) {
      error = e;
    } finally {
      _refreshing.value = false;
    }
    if (!mounted || result == null) return;
    if (showSnack) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error != null
              ? '行情刷新失败，请稍后重试'
              : result.failed == 0
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
    // Trigger the shared history sync (backfill + today's snapshot) and
    // surface its message once, like the previous page-local backfill.
    ref.watch(historySyncProvider);
    ref.listen<AsyncValue<BackfillResult?>>(historySyncProvider, (prev, next) {
      final result = next.value;
      if (result == null || !result.ok) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.message ?? '历史净值已是最新')),
        );
      });
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('总览'),
        actions: [
          Consumer(builder: (context, ref, _) {
            final hidden = ref.watch(hideAmountsProvider);
            return IconButton(
              tooltip: hidden ? '显示金额' : '隐藏金额',
              onPressed: () =>
                  ref.read(hideAmountsProvider.notifier).state = !hidden,
              icon: Icon(hidden
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
            );
          }),
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
                      // On phone: net worth trend first, then allocation.
                      // On tablet/desktop: side by side, trend on the right
                      // filling the remaining width.
                      if (Responsive.isPhone(context))
                        Column(
                          children: [
                            NetWorthChart(),
                            const SizedBox(height: 16),
                            AllocationCard(summary: s),
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

class _SummaryHeader extends ConsumerWidget {
  const _SummaryHeader({required this.summary});

  final PortfolioSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final netWorth = summary.netWorth;
    final hidden = ref.watch(hideAmountsProvider);
    // Today's earning in the snapshot view (same as the earnings
    // calendar's today cell): immune to symbol-key mismatches and
    // correct on non-trading days.
    final todayEarning = ref.watch(todayEarningProvider);
    final todayProfit = todayEarning?.profit ?? 0.0;
    final todayPct = todayEarning?.pct;
    final changeColor = context.changeColor(todayProfit);
    String amount(double v) => hidden ? Formats.masked() : '¥${Formats.amount(v)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('净资产', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              amount(netWorth),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _Chip(
                  label: '今日 ${todayPct == null ? '--' : Formats.pct(todayPct)}',
                  value: '${todayProfit >= 0 ? '+' : ''}${amount(todayProfit)}',
                  color: changeColor,
                ),
                _Chip(
                  label: '累计收益 ${Formats.pct(summary.profitPct)}',
                  value: '${summary.profit >= 0 ? '+' : ''}${amount(summary.profit)}',
                  color: context.changeColor(summary.profit),
                ),
                if (summary.realizedProfit != 0)
                  _Chip(
                    label: '已落袋收益',
                    value:
                        '${summary.realizedProfit >= 0 ? '+' : ''}${amount(summary.realizedProfit)}',
                    color: context.changeColor(summary.realizedProfit),
                  ),
                if (summary.unrealizedProfit != 0)
                  _Chip(
                    label: '当前浮盈',
                    value:
                        '${summary.unrealizedProfit >= 0 ? '+' : ''}${amount(summary.unrealizedProfit)}',
                    color: context.changeColor(summary.unrealizedProfit),
                  ),
                if (summary.totalLiabilities > 0)
                  _Chip(
                    label: '负债',
                    value: amount(summary.totalLiabilities),
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
