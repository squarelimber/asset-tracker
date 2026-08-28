import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/components/app_bar_actions.dart';
import '../../ui/tokens.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../services/market/global_quote_source.dart';

final _quotesProvider = FutureProvider<List<GlobalQuote>>((ref) async {
  return GlobalQuoteSource().fetch();
});

class MarketsPage extends ConsumerWidget {
  const MarketsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quotes = ref.watch(_quotesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('行情'),
        actions: [
          const TerminalAppBarActions(),
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
                  '数据来自新浪财经公开接口，仅供参考。',
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
class _QuoteCard extends StatelessWidget {
  const _QuoteCard({required this.quote});

  final GlobalQuote quote;

  @override
  Widget build(BuildContext context) {
    final up = quote.change >= 0;
    final color = up ? T.up : T.down;
    return SizedBox(
      width: 176,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                quote.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              Text(
                Formats.amount(quote.price),
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
    );
  }
}
