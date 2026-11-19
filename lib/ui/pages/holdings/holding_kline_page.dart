import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../core/symbols.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../../domain/holding_kline.dart';
import '../../../domain/portfolio_intraday.dart';
import '../../../services/market/kline_source.dart';
import '../../components/error_state.dart';
import '../../components/intraday_line_chart.dart';
import '../../components/kline_chart.dart';
import '../../components/terminal_card.dart';
import '../../components/terminal_choice.dart';
import '../../components/transaction_details.dart';
import '../../tokens.dart';
import '../transaction_dialogs.dart';
import 'holding_detail_sheet.dart';
import 'holding_nav_trend.dart';

/// A holding's chart and existing details share the same live data.
class HoldingKlinePage extends ConsumerWidget {
  const HoldingKlinePage({super.key, required this.holdingId, this.source})
    : _groupIds = const [];

  const HoldingKlinePage.group({super.key, required List<int> holdingIds})
    : holdingId = null,
      _groupIds = holdingIds,
      source = null;

  final int? holdingId;
  final List<int> _groupIds;
  final KlineSource? source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdings = ref.watch(holdingsProvider);
    return holdings.when(
      loading: () => _page(const Center(child: CircularProgressIndicator())),
      error: (_, _) => _page(
        ErrorState(
          message: '持仓加载失败，请重试',
          onRetry: () => ref.invalidate(holdingsProvider),
        ),
      ),
      data: (list) {
        final ids = {?holdingId, ..._groupIds};
        final matching = list
            .where((holding) => ids.contains(holding.id))
            .toList();
        if (matching.isEmpty) {
          return _page(const Center(child: Text('持仓不存在或已删除')));
        }
        if (matching.length == 1) return _page(_position(matching.single));
        final accounts =
            ref.watch(accountsProvider).valueOrNull ?? const <AccountRow>[];
        final accountNames = {
          for (final account in accounts) account.id: account.name,
        };
        return DefaultTabController(
          length: matching.length,
          child: _page(
            TabBarView(children: matching.map(_position).toList()),
            title: matching.first.name,
            tabs: TabBar(
              isScrollable: true,
              tabs: [
                for (final holding in matching)
                  Tab(
                    text: [
                      accountNames[holding.accountId] ??
                          '账户 #${holding.accountId}',
                      if (holding.symbol case final symbol?
                          when symbol.isNotEmpty)
                        symbol,
                    ].join(' · '),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _page(Widget body, {String title = '持仓详情', TabBar? tabs}) => Scaffold(
    appBar: AppBar(title: Text(title), bottom: tabs),
    body: body,
  );

  Widget _position(HoldingRow holding) {
    final symbol = klineSymbolForHolding(holding);
    return ResponsiveShell(
      child: ListView(
        key: PageStorageKey(holding.id),
        children: [
          _HoldingHeader(holding: holding),
          const SizedBox(height: T.s2),
          if (symbol != null)
            _HoldingChart(holding: holding, symbol: symbol, source: source),
          if (symbol == null &&
              (hasManualNav(holding) ||
                  holding.assetType == AssetType.mutualFund.storageName))
            HoldingNavTrend(key: ValueKey(holding.id), holding: holding),
          HoldingDetailSheet(holding: holding),
        ],
      ),
    );
  }
}

class _HoldingHeader extends ConsumerWidget {
  const _HoldingHeader({required this.holding});

  final HoldingRow holding;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(
    children: [
      Expanded(
        child: Text(
          holding.name,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(width: T.s2),
      FilledButton.tonalIcon(
        onPressed: () => showHoldingTransactionDialog(context, ref, holding),
        icon: const Icon(Icons.edit_note, size: 18),
        label: const Text('记一笔'),
      ),
    ],
  );
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
  bool _showIntraday = false;
  Future<MarketIntraday?>? _intraday;
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
    if (oldWidget.symbol != widget.symbol) {
      _intraday = null;
      if (!supportsMarketIntraday(widget.symbol)) _showIntraday = false;
      _load();
      if (_showIntraday) _loadIntraday();
    }
  }

  void _load() =>
      _bars = _source.fetch(widget.symbol, _period, adjusted: false);

  void _loadIntraday() => _intraday = _source.fetchIntraday(widget.symbol);

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
        Text(
          '${widget.symbol.toUpperCase()} · 腾讯行情 · ${_showIntraday ? '分时' : '未复权'}',
          style: T.label(),
        ),
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
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (supportsMarketIntraday(widget.symbol))
              TerminalChoice(
                label: '分时',
                selected: _showIntraday,
                onPressed: () => setState(() {
                  _showIntraday = true;
                  if (_intraday == null) _loadIntraday();
                }),
              ),
            for (final (period, label) in [
              (KlinePeriod.day, '日 K'),
              (KlinePeriod.week, '周 K'),
              (KlinePeriod.month, '月 K'),
            ])
              TerminalChoice(
                label: label,
                selected: !_showIntraday && _period == period,
                onPressed: () {
                  if (_showIntraday || _period != period) {
                    setState(() {
                      _showIntraday = false;
                      _period = period;
                      _load();
                    });
                  }
                },
              ),
            IconButton(
              tooltip: _showIntraday ? '刷新分时' : '刷新 K 线',
              onPressed: () => setState(_showIntraday ? _loadIntraday : _load),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_showIntraday)
          _buildIntraday(transactions.valueOrNull ?? const [], hidden: hide)
        else
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
                  Text(
                    '数据截至 ${Formats.date(bars.last.date)}',
                    style: T.label(),
                  ),
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

  Widget _buildIntraday(
    List<TransactionRow> transactions, {
    required bool hidden,
  }) {
    final close = widget.symbol.startsWith('hk') ? 960 : 900;
    return FutureBuilder<MarketIntraday?>(
      future: _intraday,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return ErrorState(
            message: '暂无分时行情，请稍后重试',
            onRetry: () => setState(_loadIntraday),
          );
        }
        final trades = [
          for (final t in transactions)
            if (t.holdingId == widget.holding.id &&
                (t.type == 'buy' || t.type == 'sell') &&
                todayKey(chinaMarketTime(t.occurredAt)) == data.date)
              (transaction: t, time: chinaMarketTime(t.occurredAt)),
        ];
        final markers = [
          if (!hidden)
            for (final trade in trades)
              if (trade.transaction.price case final price?)
                if (price.isFinite &&
                    price > 0 &&
                    trade.time.hour * 60 + trade.time.minute >=
                        data.points.first.minute &&
                    trade.time.hour * 60 + trade.time.minute <=
                        data.points.last.minute)
                  (
                    minute: trade.time.hour * 60 + trade.time.minute,
                    value: price,
                    color: trade.transaction.type == 'buy' ? T.up : T.down,
                  ),
        ];
        return TerminalCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${data.date} · 截至 ${minuteLabel(data.points.last.minute)} · 北京时间',
                style: T.label(),
              ),
              IntradayLineChart(
                points: data.points,
                markers: markers,
                lastMinute: close,
                morningEnd: close == 960 ? 720 : 690,
                maxGap: 2,
                formatValue: Formats.plainNum,
              ),
              if (trades.isNotEmpty)
                Wrap(
                  spacing: T.s2,
                  children: [
                    for (final trade in trades)
                      ActionChip(
                        onPressed: () =>
                            showTransactionDetails(context, trade.transaction),
                        label: Text(
                          '${trade.transaction.type == 'buy' ? '买入' : '卖出'} ${minuteLabel(trade.time.hour * 60 + trade.time.minute)}',
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
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
                    InkWell(
                      onTap: () => showTransactionDetails(context, transaction),
                      child: Padding(
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
