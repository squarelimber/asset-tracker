import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/market_session.dart';
import '../../../core/responsive.dart';
import '../../../core/symbols.dart';
import '../../../data/database.dart';
import '../../../domain/portfolio_calculator.dart';
import '../../../domain/portfolio_intraday.dart';
import '../../../services/history_backfill_service.dart';
import '../../../services/market/market_service.dart';
import '../../components/app_bar_actions.dart';
import '../../components/asset_overview_card.dart';
import '../../components/error_state.dart';
import '../../components/key_shortcuts.dart';
import '../../components/rotating_spotlight_card.dart';
import '../../components/session_chip.dart';
import '../../tokens.dart';
import '../holdings/open_holding_details.dart';
import 'day_detail_sheet.dart';
import 'portfolio_intraday.dart';
import 'portfolio_intraday_card.dart';
import 'portfolio_widgets.dart';
import 'portfolio_welcome.dart';

final summaryProvider = FutureProvider<PortfolioSummary>((ref) async {
  final dao = ref.watch(daoProvider);
  final holdings = await ref.watch(holdingsProvider.future);
  // Resolve quotes by source and holding, with a source-checked legacy fallback.
  final cacheKeys = holdingQuoteCacheKeys(holdings);
  final cache = await dao.getCachedPrices(cacheKeys);
  // Only quotes whose `change` genuinely describes today may enter the
  // prev-close map: outside the trading session (weekend, before the open)
  // an exchange still serves the previous session's close pair, and
  // counting it as today's move double-books that session.
  final now = DateTime.now();
  final prev = <int, double>{
    for (final h in holdings)
      if (cachedQuoteForHolding(cache, h) case final quote?)
        if (quote.prevClose != null && quoteObservationIsToday(
          now, fetchedAt: quote.fetchedAt, quoteDate: quote.quoteDate,
          source: MarketSource.fromStorage(h.marketSource),
        ))
          h.id: quote.prevClose!,
  };
  // Convert non-CNY holdings into CNY using the shared FX rates.
  final cnyRates = await ref.watch(cnyRatesProvider.future);
  // Realized gains from sell transactions.
  final sells = (await dao.getTransactions())
      .where((t) => t.type == TransactionType.sell.storageName)
      .toList();
  return const PortfolioCalculator().compute(
    holdings,
    prevPriceByHoldingId: prev,
    cnyRates: cnyRates,
    sellTransactions: sells,
  );
});

class PortfolioPage extends ConsumerStatefulWidget {
  const PortfolioPage({super.key, this.clock = DateTime.now});

  final DateTime Function() clock;

  @override
  ConsumerState<PortfolioPage> createState() => _PortfolioPageState();
}

class _PortfolioPageState extends ConsumerState<PortfolioPage> {
  final _refreshing = ValueNotifier<bool>(false);
  static const _intradayRefreshInterval = Duration(minutes: 5);
  late final Timer _sessionTimer;
  late final AppLifecycleListener _lifecycle;
  late MarketSession _session;
  late String _marketDay;
  DateTime? _nextIntradayRefresh;
  String? _closingSampleDay;
  DateTime? _lastRefreshAt;
  String? _refreshIssue;

  @override
  void initState() {
    super.initState();
    final time = chinaMarketTime(widget.clock());
    _session = aShareSession(time);
    _marketDay = todayKey(time);
    _lifecycle = AppLifecycleListener(
      onResume: () => _updateMarketSession(resumed: true),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nextIntradayRefresh = widget.clock().add(_intradayRefreshInterval);
      unawaited(_refreshPrices(showSnack: false));
    });
    _sessionTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _updateMarketSession(),
    );
  }

  void _updateMarketSession({bool resumed = false}) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final now = widget.clock();
    final time = chinaMarketTime(now);
    final day = todayKey(time);
    final session = aShareSession(time);
    if (session != _session || day != _marketDay) {
      setState(() {
        _session = session;
        _marketDay = day;
      });
      _nextIntradayRefresh = null;
    }
    if (resumed) _nextIntradayRefresh = null;

    if (!(ModalRoute.isCurrentOf(context) ?? true)) return;
    if (resumed && session == MarketSession.lunch) {
      ref.invalidate(portfolioIntradayHistoryProvider(day));
    }
    final closing =
        session == MarketSession.closed &&
        time.hour == 15 &&
        time.minute < 5 &&
        _closingSampleDay != day;
    if ((session != MarketSession.open && !closing) ||
        _refreshing.value ||
        (_nextIntradayRefresh?.isAfter(now) ?? false)) {
      return;
    }

    _nextIntradayRefresh = now.add(_intradayRefreshInterval);
    ref.invalidate(portfolioIntradayHistoryProvider(day));
    unawaited(_refreshPrices(showSnack: false, intradayOnly: true));
  }

  @override
  void dispose() {
    _sessionTimer.cancel();
    _lifecycle.dispose();
    _refreshing.dispose();
    super.dispose();
  }

  Future<void> _refreshPrices({
    bool showSnack = true,
    bool intradayOnly = false,
  }) async {
    if (_refreshing.value) return;
    _refreshing.value = true;
    if (showSnack) {
      ref.invalidate(
        portfolioIntradayHistoryProvider(
          todayKey(chinaMarketTime(widget.clock())),
        ),
      );
    }
    MarketRefreshResult? result;
    try {
      result = await ref.read(marketServiceProvider).refreshAll();
      if (!mounted) return;
      // Refresh quotes only — DO NOT rewrite today's snapshot here. Today's
      // row is owned by the history backfill, which prices it from these
      // fresh quotes with the SAME replay cost basis as every earlier day;
      // overwriting it with PortfolioCalculator (current quantity × current
      // costPrice) gave today a different cost basis than yesterday, showing
      // a fake daily return (the 有色/能源化工/五年国债/guozhaiEtf
      // replay-vs-current cost gaps). The backfill runs on its own trigger
      // (historySyncProvider) and reacts to the refresh.
      if (!intradayOnly) ref.invalidate(historySyncProvider);
      // FX rates may have changed with the refresh.
      ref.invalidate(cnyRatesProvider);
      // Prices are fresh: re-evaluate alert rules and notify for anything
      // newly fired (no-op when disabled or nothing changed today).
      if (!intradayOnly) {
        unawaited(ref.read(alertNotificationServiceProvider).checkAndNotify());
      }
      final time = chinaMarketTime(result.fetchedAt);
      final session = aShareSession(time);
      final closing =
          session == MarketSession.closed && time.hour == 15 && time.minute < 5;
      if (result.updated > 0 &&
          (session == MarketSession.open ||
              (session == MarketSession.lunch &&
                  time.hour == 11 &&
                  time.minute == 30) ||
              closing)) {
        try {
          await recordPortfolioSample(
            ref.read(daoProvider),
            ref.read(marketServiceProvider),
            result.fetchedAt,
          );
          if (closing) _closingSampleDay = todayKey(time);
        } catch (error, stack) {
          debugPrint('Intraday sample failed: $error\n$stack');
        }
      }
    } catch (_) {
      result = null;
    } finally {
      if (mounted) _refreshing.value = false;
    }
    if (!mounted) return;
    final String message;
    if (result == null || (result.updated == 0 && result.failed > 0)) {
      message = '行情刷新失败，请稍后重试';
      setState(() => _refreshIssue = '行情刷新失败');
    } else if (result.updated == 0) {
      message = '暂无可更新行情';
      setState(() => _refreshIssue = message);
    } else {
      final failed = result.failed;
      final fetchedAt = result.fetchedAt;
      message = failed == 0
          ? '行情已更新 (${result.updated} 项)'
          : '更新 ${result.updated} 项，失败 $failed 项';
      setState(() {
        _lastRefreshAt = fetchedAt;
        _refreshIssue = failed == 0 ? null : '$failed 项未更新';
      });
    }
    if (showSnack) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(summaryProvider);
    final holdings = ref.watch(holdingsProvider);
    // Updating today's snapshot is part of the regular quote refresh.
    ref.watch(historySyncProvider);
    ref.listen<AsyncValue<BackfillResult?>>(historySyncProvider, (prev, next) {
      if (next.isLoading) return;
      final result = next.asData?.value;
      if (result == null ||
          (!result.historyUnavailable &&
              (!result.ok || result.historicalDays == 0))) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !(ModalRoute.isCurrentOf(context) ?? true)) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(
          content: Text(result.message ?? '历史净值已是最新'),
          action: result.historyUnavailable
              ? SnackBarAction(
                  label: '重试',
                  onPressed: () {
                    if (mounted) ref.invalidate(historySyncProvider);
                  },
                )
              : null,
        ));
      });
    });
    return KeyShortcuts(
      onKeyDown: (key) {
        if (key == LogicalKeyboardKey.keyR) _refreshPrices(showSnack: true);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('总览'),
          actions: [
            const TerminalAppBarActions(),
            ValueListenableBuilder<bool>(
              valueListenable: _refreshing,
              builder: (context, refreshing, _) {
                final icon = refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18);
                final label = refreshing ? '正在刷新行情' : '刷新行情';
                final VoidCallback? onPressed = refreshing
                    ? null
                    : _refreshPrices;
                if (Responsive.isDesktop(context)) {
                  return Padding(
                    padding: const EdgeInsets.only(right: T.s3),
                    child: TextButton.icon(
                      onPressed: onPressed,
                      icon: icon,
                      label: Text(label),
                    ),
                  );
                }
                return IconButton(
                  tooltip: label,
                  onPressed: onPressed,
                  icon: icon,
                );
              },
            ),
          ],
        ),
        body: holdings.when(
          data: (list) {
            if (list.isEmpty) {
              return PortfolioWelcome(
                hasAccounts:
                    ref.watch(accountsProvider).valueOrNull?.isNotEmpty ??
                    false,
              );
            }
            // 保留上一次成功的汇总值：行情/汇率后台刷新会 invalidate
            // summaryProvider 使其短暂进入 loading —— 此时若用 when 的
            // loading 分支会把整个 ListView（含净值趋势图）卸载，图表内部
            // 的视图/区间/指数选择全部重置，表现成"总览页重新加载、跳回
            // 总览"。用 valueOrNull 在重算期间继续渲染旧数据，只在真正
            // 首次加载（无旧值）时显示全屏 loading。
            final s = summary.valueOrNull;
            if (s == null) {
              return summary.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ErrorState(
                  message: '总览计算失败，请重试',
                  onRetry: () => ref.invalidate(summaryProvider),
                ),
                data: (v) => _buildBody(v),
              );
            }
            return Stack(
              children: [
                _buildBody(s),
                if (summary.isLoading)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(
            message: '持仓数据加载失败，请重试',
            onRetry: () => ref.invalidate(holdingsProvider),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(PortfolioSummary s) {
    final context = this.context;
    return RefreshIndicator(
      onRefresh: () => _refreshPrices(showSnack: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(Responsive.isPhone(context) ? T.s3 : T.s5),
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: _refreshing,
            builder: (context, refreshing, _) => Wrap(
              spacing: T.s2,
              runSpacing: T.s1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SessionChip(session: _session),
                if (refreshing)
                  Text('正在刷新行情…', style: T.label())
                else ...[
                  if (_lastRefreshAt case final time?)
                    Text(
                      '行情更新于 ${Formats.dateTime(time)}',
                      style: T.label(color: T.text3),
                    ),
                  if (_refreshIssue case final issue?)
                    Text(issue, style: T.label()),
                ],
              ],
            ),
          ),
          const SizedBox(height: T.s2),
          if (s.missingCurrencies.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _showPendingConversions(s.missingCurrencies),
                icon: const Icon(Icons.info_outline, size: 16, color: T.warning),
                label: Text(
                  '部分资产待折算 · ${(s.missingCurrencies.toList()..sort()).join('、')}',
                  style: T.label(color: T.warning),
                ),
              ),
            ),
          _KpiRow(summary: s),
          const SizedBox(height: T.s3),
          PortfolioIntradayCard(day: _marketDay, session: _session),
          // 轮动焦点卡：今日最佳 / 今日最差 / 本月最佳（自动切换）。
          const RotatingSpotlightCard(),
          const SizedBox(height: T.s3),
          LayoutBuilder(
            builder: (context, constraints) {
              // Use the content width: the desktop sidebar consumes space too.
              if (constraints.maxWidth < 1000) {
                return Column(
                  children: [
                    NetWorthChart(),
                    const SizedBox(height: T.s3),
                    AllocationCard(summary: s),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: NetWorthChart()),
                  const SizedBox(width: T.s3),
                  Expanded(flex: 2, child: AllocationCard(summary: s)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showPendingConversions(Set<String> currencies) async {
    final holdings =
        ref.read(holdingsProvider).valueOrNull ?? const <HoldingRow>[];
    final rates =
        ref.read(cnyRatesProvider).valueOrNull ?? const <String, double>{};
    final hide = ref.read(hideAmountsProvider);
    final pending = holdings
        .where(
          (row) =>
              row.quantity != 0 &&
              currencies.contains(row.currency.toUpperCase()) &&
              valueRateOfOrNull(row, rates) == null,
        )
        .toList();
    final unlisted =
        currencies
            .difference(
              pending.map((row) => row.currency.toUpperCase()).toSet(),
            )
            .toList()
          ..sort();
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * .75,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(T.s4, 0, T.s4, T.s4),
            children: [
              Text(
                '待折算资产',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: T.s2),
              const Text('人民币汇总仅包含已有汇率的金额。'),
              for (final row in pending)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(row.name),
                  subtitle: Text('缺少 ${row.currency} 汇率'),
                  trailing: Text(
                    hide
                        ? Formats.masked()
                        : Formats.money(
                            AssetType.fromStorage(row.assetType)
                                        .isAmountBased ||
                                    AssetType.fromStorage(row.assetType) ==
                                        AssetType.liability
                                ? row.quantity
                                : row.quantity * row.latestPrice,
                            row.currency,
                          ),
                  ),
                  onTap: () => Navigator.pop(sheetContext, row.id),
                ),
              if (unlisted.isNotEmpty)
                Text('${unlisted.join('、')} 的历史收益或成本也有待折算。'),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      await openHoldingDetails(context, selected);
    }
  }
}

class _KpiRow extends ConsumerWidget {
  const _KpiRow({required this.summary});

  final PortfolioSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(hideAmountsProvider);
    final todayEarning = ref.watch(todayEarningProvider);
    return AssetOverviewCard(
      totalAssets: summary.totalAssets,
      totalLiabilities: summary.totalLiabilities,
      netWorth: summary.netWorth,
      todayProfit: todayEarning?.profit,
      todayPct: todayEarning?.pct,
      todayLabel: '今日快照收益',
      todaySource: todayEarning == null
          ? '缺少可比较的快照'
          : '快照更新 ${Formats.dateTime(todayEarning.updatedAt.toLocal())}',
      onOpenEarnings: () => context.push(
        '/earnings-calendar?date=${Formats.date(DateTime.now())}',
      ),
      onOpenTodayDetail: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) {
          final now = DateTime.now();
          return DayDetailSheet(
            date: now,
            intradayKey: todayKey(chinaMarketTime(now)),
          );
        },
      ),
      hidden: hidden,
      onToggleHidden: () {
        final now = ref.read(hideAmountsProvider);
        ref.read(hideAmountsProvider.notifier).state = !now;
      },
    );
  }
}
