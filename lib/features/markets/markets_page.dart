import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../services/market/futures_kline_source.dart';
import '../../services/market/global_quote_source.dart';
import '../../services/market/history_lookup.dart';
import '../../services/market/history_source.dart';
import '../../services/market/tencent_history_source.dart';

final _quotesProvider = FutureProvider<List<GlobalQuote>>((ref) async {
  return GlobalQuoteSource().fetch();
});

/// Trend history for a quote code, when available:
/// A-share indices via the Sina K-line API; commodities via domestic futures.
/// On the web the CORS-friendly Tencent K-line endpoint is used instead.
final _trendProvider = FutureProvider.autoDispose.family<List<FlSpot>, String>(
  (ref, code) async {
    final symbol = _historySymbol(code);
    if (symbol == null) return const [];
    final now = DateTime.now();
    final HistoryDataSource source = kIsWeb
        ? TencentHistorySource()
        : (code.startsWith('hf_')
            ? FuturesKLineSource()
            : SinaKLineSource());
    final history = await source.fetch(symbol, now.subtract(const Duration(days: 900)), now);
    if (history.isEmpty) return const [];
    final lookup = HistoryPriceLookup(history);
    final keys = history.keys.toList()..sort();
    return [
      for (var i = 0; i < keys.length; i++)
        FlSpot(i.toDouble(), lookup.priceOnOrBefore(keys[i]) ?? 0),
    ];
  },
);

String? _historySymbol(String code) {
  if (code.startsWith('sh') || code.startsWith('sz')) return code;
  // Tencent has no domestic futures K-lines, so commodity trends are
  // unavailable on the web.
  if (kIsWeb && code.startsWith('hf_')) return null;
  if (code.startsWith('hf_')) {
    return switch (code) {
      'hf_XAU' || 'hf_GC' => 'AU0', // 沪金
      'hf_CL' || 'hf_OIL' => 'SC0', // 沪油
      'hf_HG' => 'CU0', // 沪铜
      _ => null,
    };
  }
  return null;
}

class MarketsPage extends ConsumerWidget {
  const MarketsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quotes = ref.watch(_quotesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('行情'),
        actions: [
          IconButton(
            tooltip: '刷新行情',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(_quotesProvider),
          ),
        ],
      ),
      body: quotes.when(
        data: (list) {
          if (list.isEmpty) {
            return const Center(child: Text('行情加载失败，请检查网络后刷新'));
          }
          final groups = <String, List<GlobalQuote>>{};
          for (final q in list) {
            groups.putIfAbsent(q.group, () => []).add(q);
          }
          final groupNames = ['A股', '亚太', '欧美', '大宗商品', '货币'];
          return ResponsiveShell(
            child: ListView(
              children: [
                for (final name in groupNames)
                  if (groups.containsKey(name)) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(name, style: Theme.of(context).textTheme.titleMedium),
                    ),
                    // Xueqiu-style horizontal card strip.
                    SizedBox(
                      height: 118,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: groups[name]!.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, i) =>
                            _QuoteCard(quote: groups[name]![i]),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                const SizedBox(height: 8),
                Text(
                  '数据来自新浪财经公开接口，仅供参考。海外指数暂不支持历史走势。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
    );
  }
}

/// Xueqiu-style quote card: name, big price, colored change badge.
class _QuoteCard extends ConsumerWidget {
  const _QuoteCard({required this.quote});

  final GlobalQuote quote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final up = quote.change >= 0;
    final color = up ? AppColors.up : AppColors.down;
    final hasTrend = _historySymbol(quote.code) != null;
    return SizedBox(
      width: 176,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: hasTrend ? () => _showTrend(context, ref) : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        quote.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (hasTrend)
                      const Icon(Icons.chevron_right, size: 14),
                  ],
                ),
                const Spacer(),
                Text(
                  quote.fxSymbol != null
                      ? Formats.amount(quote.price)
                      : Formats.amount(quote.price),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: quote.fxSymbol == null ? 22 : 18,
                      ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${quote.changePct >= 0 ? '+' : ''}${Formats.pct(quote.changePct)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${quote.change >= 0 ? '+' : ''}${Formats.amount(quote.change)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: color,
                            ),
                      ),
                    ),
                  ],
                ),
                if (quote.fxSymbol != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    '1 ${quote.fxSymbol} = ${Formats.amount(quote.price)} CNY',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showTrend(BuildContext context, WidgetRef ref) async {
    final symbol = _historySymbol(quote.code)!;
    final isCommodity = quote.code.startsWith('hf_');
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _QuoteTrendSheet(
        title: quote.name,
        symbol: symbol,
        unitLabel: isCommodity ? '（${symbol == 'AU0' ? '沪金·元/克' : symbol == 'SC0' ? '沪油·元/桶' : '沪铜·元/吨'}）' : '',
        trend: ref.watch(_trendProvider(quote.code)),
      ),
    );
  }
}

class _QuoteTrendSheet extends StatelessWidget {
  const _QuoteTrendSheet({
    required this.title,
    required this.symbol,
    required this.unitLabel,
    required this.trend,
  });

  final String title;
  final String symbol;
  final String unitLabel;
  final AsyncValue<List<FlSpot>> trend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$title 近三年走势$unitLabel',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            SizedBox(
              height: 240,
              child: trend.when(
                data: (spots) {
                  if (spots.isEmpty) {
                    return const Center(child: Text('暂无历史数据'));
                  }
                  var minV = double.infinity;
                  var maxV = 0.0;
                  for (final s in spots) {
                    if (s.y < minV) minV = s.y;
                    if (s.y > maxV) maxV = s.y;
                  }
                  final span = maxV - minV;
                  final pad = span == 0 ? maxV * 0.05 : span * 0.1;
                  return LineChart(
                    LineChartData(
                      minY: (minV - pad).clamp(0, double.infinity),
                      maxY: maxV + pad,
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: span == 0 ? 1 : span / 4,
                        getDrawingHorizontalLine: (v) => FlLine(
                          color: Theme.of(context)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.3),
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 52,
                            getTitlesWidget: (v, meta) => Text(
                              Formats.amountCompact(v),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                        bottomTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          curveSmoothness: 0.25,
                          color: AppColors.up,
                          barWidth: 2,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: AppColors.up.withValues(alpha: 0.08),
                          ),
                        ),
                      ],
                    ),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('加载失败: $e')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
