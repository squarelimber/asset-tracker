import 'package:flutter/material.dart';

import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../services/market/kline_source.dart';
import '../../components/error_state.dart';
import '../../components/kline_chart.dart';
import '../../components/terminal_choice.dart';
import '../../tokens.dart';

/// Historical candlesticks for an index or a searched security.
class KlinePage extends StatefulWidget {
  const KlinePage({
    super.key,
    this.initialSymbol = 'sh000001',
    this.initialName,
    this.source,
  });

  final String initialSymbol;
  final String? initialName;
  final KlineSource? source;

  @override
  State<KlinePage> createState() => _KlinePageState();
}

class _KlinePageState extends State<KlinePage> {
  static const _symbols = {
    'sh000001': '上证指数',
    'sz399001': '深证成指',
    'sz399006': '创业板指',
  };

  late String _symbol;
  late final KlineSource _source;
  KlinePeriod _period = KlinePeriod.day;
  late Future<List<CandleBar>> _bars;

  @override
  void initState() {
    super.initState();
    _source = widget.source ?? KlineSource();
    _symbol = widget.initialSymbol;
    _load();
  }

  void _load() {
    _bars = _source.fetch(_symbol, _period);
  }

  @override
  void dispose() {
    if (widget.source == null) _source.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isIndex = _symbols.containsKey(_symbol);
    final name = _symbols[_symbol] ?? widget.initialName ?? _symbol;
    return Scaffold(
      appBar: AppBar(title: Text(isIndex ? '指数 K 线' : '证券 K 线')),
      body: ResponsiveShell(
        child: ListView(
          children: [
            if (isIndex)
              Wrap(
                spacing: T.s2,
                runSpacing: T.s1,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final entry in _symbols.entries)
                    TerminalChoice(
                      label: entry.value,
                      selected: _symbol == entry.key,
                      onPressed: () {
                        if (_symbol == entry.key) return;
                        setState(() {
                          _symbol = entry.key;
                          _load();
                        });
                      },
                    ),
                ],
              ),
            if (isIndex) const SizedBox(height: T.s3),
            Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: T.s2),
                Text(
                  _symbol.toUpperCase(),
                  style: T.mono(size: 11, color: T.text3),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '刷新 K 线',
                  onPressed: () => setState(_load),
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
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
                      if (_period == period) return;
                      setState(() {
                        _period = period;
                        _load();
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: T.s2),
            FutureBuilder<List<CandleBar>>(
              key: ValueKey('$_symbol-$_period'),
              future: _bars,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(
                    height: 380,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final bars = snapshot.data ?? const <CandleBar>[];
                if (snapshot.hasError || bars.isEmpty) {
                  return SizedBox(
                    height: 380,
                    child: ErrorState(
                      message: '未能获取 K 线数据，请检查网络后重试',
                      onRetry: () => setState(_load),
                    ),
                  );
                }
                final latest = bars.last;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '最近 K 线  ${Formats.num(latest.close)}',
                      style: T.mono(size: 19, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: T.s1),
                    Text(
                      '数据截至 ${Formats.date(latest.date)} · 腾讯行情',
                      style: T.label(),
                    ),
                    if (DateTime.now().difference(latest.date).inDays > 14)
                      Text('行情已较长时间未更新，证券可能已停牌或退市。', style: T.label()),
                    const SizedBox(height: T.s3),
                    KlineChart(bars: bars),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
