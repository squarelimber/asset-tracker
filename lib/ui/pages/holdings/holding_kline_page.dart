import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../../domain/holding_kline.dart';
import '../../../services/market/kline_source.dart';
import '../../components/error_state.dart';
import '../../components/kline_chart.dart';
import '../../components/terminal_card.dart';
import '../../components/terminal_choice.dart';
import '../../tokens.dart';
import '../transaction_dialogs.dart';
import 'holding_detail_sheet.dart';

/// A holding's chart and existing details share the same live data.
class HoldingKlinePage extends ConsumerWidget {
  const HoldingKlinePage({super.key, required this.holdingId, this.source});

  final int holdingId;
  final KlineSource? source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdings = ref.watch(holdingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('持仓详情')),
      body: holdings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => ErrorState(
          message: '持仓加载失败，请重试',
          onRetry: () => ref.invalidate(holdingsProvider),
        ),
        data: (list) {
          final matching = list.where((holding) => holding.id == holdingId);
          if (matching.isEmpty) {
            return const Center(child: Text('持仓不存在或已删除'));
          }
          final holding = matching.first;
          final symbol = klineSymbolForHolding(holding);
          return ResponsiveShell(
            child: ListView(
              children: [
                if (symbol != null)
                  _HoldingChart(
                    holding: holding,
                    symbol: symbol,
                    source: source,
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: T.s3),
                    child: Text(
                      holding.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                HoldingDetailSheet(
                  holding: holding,
                  embedded: true,
                  showTransactionButton: symbol == null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HoldingChart extends ConsumerStatefulWidget {
  const _HoldingChart({
    required this.holding,
    required this.symbol,
    this.source,
  });
  final HoldingRow holding;
  final String symbol;
  final KlineSource? source;

  @override
  ConsumerState<_HoldingChart> createState() => _HoldingChartState();
}

class _HoldingChartState extends ConsumerState<_HoldingChart> {
  late final KlineSource _source;
  KlinePeriod _period = KlinePeriod.day;
  late Future<List<CandleBar>> _bars;

  @override
  void initState() {
    super.initState();
    _source = widget.source ?? KlineSource();
    _load();
  }

  @override
  void didUpdateWidget(covariant _HoldingChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.symbol != widget.symbol) _load();
  }

  void _load() =>
      _bars = _source.fetch(widget.symbol, _period, adjusted: false);

  @override
  void dispose() {
    if (widget.source == null) _source.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final holding = widget.holding;
    final hide = ref.watch(hideAmountsProvider);
    final transactions = ref.watch(transactionsByHoldingProvider(holding.id));
    final markers = buildKlineTradeMarkers(
      transactions.valueOrNull ?? const [],
      holding.id,
    );
    final value = holding.quantity * holding.latestPrice;
    final profit = value - holding.quantity * holding.costPrice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                holding.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () =>
                  showHoldingTransactionDialog(context, ref, holding),
              icon: const Icon(Icons.edit_note),
              label: const Text('记一笔'),
            ),
          ],
        ),
        Text('${widget.symbol.toUpperCase()} · 腾讯行情 · 未复权', style: T.label()),
        const SizedBox(height: T.s2),
        Wrap(
          spacing: T.s4,
          runSpacing: T.s1,
          children: [
            Text(
              '持有市值 ${hide ? '****' : Formats.money(value, holding.currency)}',
              style: T.mono(size: 12),
            ),
            if (!isHoldingClosed(holding))
              Text(
                '持仓收益 ${hide ? '****' : Formats.money(profit, holding.currency)}',
                style: T.mono(
                  size: 12,
                  color: hide ? T.text1 : T.changeColor(profit),
                ),
              ),
            Text(
              '成本价 ${hide ? '****' : Formats.plainNum(holding.costPrice)}',
              style: T.mono(size: 12),
            ),
          ],
        ),
        const SizedBox(height: T.s2),
        Row(
          children: [
            for (final (period, label) in [
              (KlinePeriod.day, '日 K'),
              (KlinePeriod.week, '周 K'),
              (KlinePeriod.month, '月 K'),
            ])
              TerminalChoice(
                label: label,
                selected: _period == period,
                onPressed: () {
                  if (_period != period) {
                    setState(() {
                      _period = period;
                      _load();
                    });
                  }
                },
              ),
            const Spacer(),
            IconButton(
              tooltip: '刷新 K 线',
              onPressed: () => setState(_load),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        FutureBuilder<List<CandleBar>>(
          future: _bars,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final bars = snapshot.data ?? const <CandleBar>[];
            if (snapshot.hasError || bars.isEmpty) {
              return ErrorState(
                message: '未能获取 K 线数据，请检查网络后重试',
                onRetry: () => setState(_load),
              );
            }
            final matched = mapKlineMarkersToBars(
              bars,
              markers,
              _period,
            ).values.fold<int>(0, (count, items) => count + items.length);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('数据截至 ${Formats.date(bars.last.date)}', style: T.label()),
                if (DateTime.now().difference(bars.last.date).inDays > 14)
                  Text('行情已较长时间未更新，证券可能已停牌或退市。', style: T.label()),
                TerminalCard(
                  child: KlineChart(
                    bars: bars,
                    period: _period,
                    markers: markers,
                    hideTradePrices: hide,
                    onMarkerTap: (items) => _showMarkers(context, items),
                  ),
                ),
                if (matched < markers.length)
                  Text('部分交易无对应 K 线，可在下方交易流水查看。', style: T.label()),
              ],
            );
          },
        ),
        if (transactions.isLoading) Text('交易标记加载中…', style: T.label()),
        if (transactions.hasError)
          TextButton(
            onPressed: () =>
                ref.invalidate(transactionsByHoldingProvider(holding.id)),
            child: const Text('交易标记加载失败，点击重试'),
          ),
        Text(
          hide
              ? 'B 买入 · S 卖出 · T 同日买卖（按本地记录日期）。金额隐藏时，标记仅显示日期。'
              : 'B 买入 · S 卖出 · T 同日买卖（按本地记录日期）。标记按原始成交价格定位，相邻标记可能合并。',
          style: T.label(),
        ),
        if (widget.symbol.startsWith('us'))
          Text('美股交易请将记录日期设为交易所的成交日期。', style: T.label()),
        const SizedBox(height: T.s4),
      ],
    );
  }

  void _showMarkers(BuildContext context, List<KlineTradeMarker> markers) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final hide = ref.watch(hideAmountsProvider);
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(T.s4),
              children: [
                const Text(
                  '交易记录',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                for (final marker in markers) ...[
                  const SizedBox(height: T.s2),
                  Text(Formats.date(marker.date), style: T.label()),
                  for (final transaction in marker.transactions)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: T.s2),
                      child: Text(
                        [
                          transaction.type == 'buy' ? '买入' : '卖出',
                          if (transaction.price != null)
                            '成交价 ${hide ? '****' : Formats.plainNum(transaction.price!)}',
                          if (transaction.quantity != null)
                            '数量 ${hide ? '****' : Formats.smartNum(transaction.quantity!)}',
                          '金额 ${hide ? '****' : Formats.money(transaction.amount, transaction.currency)}',
                        ].join(' · '),
                        style: T.mono(size: 12),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
