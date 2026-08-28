import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../domain/portfolio_calculator.dart';
import '../../../services/history_backfill_service.dart';
import '../../../services/market/market_service.dart';
import '../../components/app_bar_actions.dart';
import '../../components/empty_state.dart';
import '../../components/kpi_grid.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';
import 'portfolio_widgets.dart';

final summaryProvider = FutureProvider<PortfolioSummary>((ref) async {
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
    final summary = ref.watch(summaryProvider);
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
          const TerminalAppBarActions(),
          Consumer(builder: (context, ref, _) {
            final hidden = ref.watch(hideAmountsProvider);
            return IconButton(
              tooltip: hidden ? '显示金额' : '隐藏金额',
              onPressed: () =>
                  ref.read(hideAmountsProvider.notifier).state = !hidden,
              icon: Icon(
                hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                color: T.text2,
              ),
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
                  : const Icon(Icons.refresh, color: T.text2),
            ),
          ),
        ],
      ),
      body: holdings.when(
        data: (list) => list.isEmpty
            ? const EmptyState(
                message: '还没有持仓数据\n去"持仓"页添加你的第一笔资产吧',
              )
            : ResponsiveShell(
                child: summary.when(
                  data: (s) => ListView(
                    padding: const EdgeInsets.all(T.s3),
                    children: [
                      _KpiRow(summary: s),
                      const SizedBox(height: T.s3),
                      if (Responsive.isPhone(context)) ...[
                        NetWorthChart(),
                        const SizedBox(height: T.s3),
                        AllocationCard(summary: s),
                      ] else ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 2, child: NetWorthChart()),
                            const SizedBox(width: T.s3),
                            Expanded(flex: 1, child: AllocationCard(summary: s)),
                          ],
                        ),
                        const SizedBox(height: T.s3),
                      ],
                      _CalendarEntries(),
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

class _KpiRow extends ConsumerWidget {
  const _KpiRow({required this.summary});

  final PortfolioSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(hideAmountsProvider);
    String amount(double v) => hidden ? Formats.masked() : Formats.amount(v);
    final todayEarning = ref.watch(todayEarningProvider);
    final todayProfit = todayEarning?.profit ?? 0.0;
    return KpiGrid(
      tiles: [
        StatTile(label: '总资产', value: amount(summary.totalAssets)),
        StatTile(
          label: '总负债',
          value: amount(summary.totalLiabilities),
          color: T.text2,
        ),
        StatTile(
          label: '净资产',
          value: amount(summary.netWorth),
          delta: todayEarning?.pct,
        ),
        StatTile(
          label: '今日盈亏',
          value: '${todayProfit >= 0 ? '+' : ''}${amount(todayProfit)}',
          color: T.changeColor(todayProfit),
        ),
      ],
    );
  }
}

class _CalendarEntries extends StatelessWidget {
  const _CalendarEntries();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _EntryTile(
            icon: Icons.calendar_month_outlined,
            label: '收益日历',
            onTap: () => context.go('/earnings-calendar'),
          ),
        ),
        const SizedBox(width: T.s3),
        Expanded(
          child: _EntryTile(
            icon: Icons.table_chart_outlined,
            label: '产品收益日历',
            onTap: () => context.go('/product-earnings'),
          ),
        ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TerminalCard(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: T.accent),
          const SizedBox(width: T.s2),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: T.text1),
            ),
          ),
          const Icon(Icons.chevron_right, size: 18, color: T.text3),
        ],
      ),
    );
  }
}
