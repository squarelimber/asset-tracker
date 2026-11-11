import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/formats.dart';
import '../../../core/global_market_session.dart';
import '../../../core/responsive.dart';
import '../../../services/market/global_quote_source.dart';
import '../../components/app_bar_actions.dart';
import '../../components/delta_text.dart';
import '../../components/error_state.dart';
import '../../components/key_shortcuts.dart';
import '../../components/quote_table.dart';
import '../../components/terminal_choice.dart';
import '../../tokens.dart';

/// In-memory TTL cache so revisiting the page (or re-entering the provider)
/// does not refetch and flash a spinner within [ttl].
final _quotesCache = _QuotesCache();

class _QuotesCache {
  static const ttl = Duration(seconds: 60);

  List<GlobalQuote>? items;
  DateTime? fetchedAt;

  bool get isFresh =>
      items != null &&
      fetchedAt != null &&
      DateTime.now().difference(fetchedAt!) < ttl;
}

final quotesProvider = FutureProvider<List<GlobalQuote>>((ref) async {
  if (_quotesCache.isFresh) return _quotesCache.items!;
  return GlobalQuoteSource().fetch();
});

QuoteMarket _marketForGroup(String group) => switch (group) {
  'A股' => QuoteMarket.china,
  '港股' => QuoteMarket.hongKong,
  '日股' => QuoteMarket.japan,
  '美股' => QuoteMarket.us,
  '商品' => QuoteMarket.commodity,
  _ => QuoteMarket.forex,
};

String _sessionLabel(String group) =>
    quoteMarketSessionLabel(quoteMarketSession(_marketForGroup(group)));

bool _sessionOpen(String group) =>
    quoteMarketSession(_marketForGroup(group)) == QuoteMarketSession.open;

class MarketsPage extends ConsumerStatefulWidget {
  const MarketsPage({super.key});

  @override
  ConsumerState<MarketsPage> createState() => _MarketsPageState();
}

class _MarketsPageState extends ConsumerState<MarketsPage> {
  final _refreshing = ValueNotifier<bool>(false);
  String _selectedGroup = '全部';
  late final Timer _sessionTimer;

  static const _groupNames = ['A股', '港股', '日股', '美股', '商品', '汇率'];

  @override
  void initState() {
    super.initState();
    _sessionTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sessionTimer.cancel();
    _refreshing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final quotes = ref.watch(quotesProvider);
    return KeyShortcuts(
      onKeyDown: (key) {
        if (key == LogicalKeyboardKey.keyR) _refresh(showSnack: true);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('行情'),
          actions: [
            IconButton(
              tooltip: '搜索股票和 ETF',
              icon: const Icon(Icons.search),
              onPressed: () => context.push('/markets/search'),
            ),
            IconButton(
              tooltip: '指数 K 线',
              icon: const Icon(Icons.candlestick_chart_outlined),
              onPressed: () => context.push('/markets/kline'),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _refreshing,
              builder: (context, refreshing, _) {
                final label = refreshing ? '正在刷新行情' : '刷新行情';
                final icon = refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18);
                final onPressed = refreshing
                    ? null
                    : () => _refresh(showSnack: true);
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
                  icon: icon,
                  onPressed: onPressed,
                );
              },
            ),
            const TerminalAppBarActions(),
          ],
        ),
        body: quotes.when(
          data: (list) {
            if (list.isEmpty) {
              return ErrorState(
                message: '行情加载失败，请检查网络后刷新',
                onRetry: () => ref.invalidate(quotesProvider),
              );
            }
            final groups = <String, List<GlobalQuote>>{};
            for (final q in list) {
              final group = switch (q.group) {
                'A股' => 'A股',
                '亚太' => q.code.startsWith('rt_hk') ? '港股' : '日股',
                '欧美' => '美股',
                '大宗商品' => '商品',
                '货币' => '汇率',
                _ => q.group,
              };
              groups.putIfAbsent(group, () => []).add(q);
            }
            final tables = [
              for (final name in _groupNames)
                if (groups.containsKey(name) &&
                    (_selectedGroup == '全部' || _selectedGroup == name))
                  (
                    name,
                    [
                      for (final q in groups[name]!)
                        QuoteRow(
                          code: q.code,
                          name: q.name,
                          price: q.price,
                          change: q.change,
                          changePct: q.changePct,
                          unit: q.unit,
                          fxSymbol: q.fxSymbol,
                        ),
                    ],
                  ),
            ];
            return ResponsiveShell(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: T.s3),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final group in ['全部', ..._groupNames])
                              Padding(
                                padding: const EdgeInsets.only(right: T.s1),
                                child: SizedBox(
                                  width: 64,
                                  child: TerminalChoice(
                                    label: group,
                                    selected: _selectedGroup == group,
                                    onPressed: () =>
                                        setState(() => _selectedGroup = group),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (tables.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: T.s5),
                        child: Center(child: Text('该分类暂无行情')),
                      ),
                    if (Responsive.isDesktop(context))
                      _GroupGrid(tables: tables, onQuoteTap: _showQuoteDetail)
                    else
                      for (final (name, rows) in tables)
                        QuoteTable(
                          group: name,
                          rows: rows,
                          onQuoteTap: _showQuoteDetail,
                          sessionLabel: _sessionLabel(name),
                          sessionOpen: _sessionOpen(name),
                        ),
                    const SizedBox(height: T.s2),
                    Text(
                      '数据来自${kIsWeb ? '腾讯' : '新浪'}财经公开接口，仅供参考。',
                      style: T.label(),
                    ),
                  ],
                ),
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(
            message: '行情加载失败，请检查网络后重试',
            onRetry: () => ref.invalidate(quotesProvider),
          ),
        ),
      ),
    );
  }

  Future<void> _refresh({bool showSnack = false}) async {
    if (_refreshing.value) return;
    _refreshing.value = true;
    try {
      final fresh = await GlobalQuoteSource().fetch();
      if (!mounted) return;
      if (fresh.isNotEmpty) {
        _quotesCache.items = fresh;
        _quotesCache.fetchedAt = DateTime.now();
        ref.invalidate(quotesProvider);
      }
      if (showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(fresh.isEmpty ? '未获取到行情数据' : '行情已更新')),
        );
      }
    } catch (_) {
      if (showSnack && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _quotesCache.items != null ? '刷新失败，显示缓存数据' : '行情刷新失败，请稍后重试',
            ),
          ),
        );
      }
    } finally {
      if (mounted) _refreshing.value = false;
    }
  }

  void _showQuoteDetail(QuoteRow r) {
    if (const {'sh000001', 'sz399001', 'sz399006'}.contains(r.code)) {
      context.push(
        Uri(
          path: '/markets/kline',
          queryParameters: {'symbol': r.code},
        ).toString(),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(T.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              r.name,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: T.text1,
              ),
            ),
            const SizedBox(height: 2),
            Text(r.code, style: T.mono(size: 12, color: T.text3)),
            const SizedBox(height: T.s3),
            Text(
              r.fxSymbol != null
                  ? r.price.toStringAsFixed(4)
                  : Formats.num(r.price),
              style: T.mono(size: 26, weight: FontWeight.w700),
            ),
            const SizedBox(height: T.s2),
            DeltaText(
              value: r.changePct,
              text:
                  '${r.changePct >= 0 ? '+' : ''}${Formats.pct(r.changePct)}  '
                  '${r.change >= 0 ? '+' : ''}${Formats.amount(r.change)}',
            ),
            if (r.fxSymbol != null) ...[
              const SizedBox(height: T.s2),
              Text(
                '1 ${r.fxSymbol} = ${r.price.toStringAsFixed(4)} CNY',
                style: T.mono(size: 12, color: T.text2),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Desktop: group quote tables in two balanced columns.
class _GroupGrid extends StatelessWidget {
  const _GroupGrid({required this.tables, required this.onQuoteTap});

  final List<(String, List<QuoteRow>)> tables;
  final void Function(QuoteRow) onQuoteTap;

  @override
  Widget build(BuildContext context) {
    final mid = (tables.length + 1) ~/ 2;
    Widget column(List<(String, List<QuoteRow>)> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (name, rows) in items)
          QuoteTable(
            group: name,
            rows: rows,
            onQuoteTap: onQuoteTap,
            sessionLabel: _sessionLabel(name),
            sessionOpen: _sessionOpen(name),
          ),
      ],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: column(tables.take(mid).toList())),
        const SizedBox(width: T.s3),
        Expanded(child: column(tables.skip(mid).toList())),
      ],
    );
  }
}
