import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import 'market_data_source.dart';

/// Sina Finance quote source for A-share stocks, ETFs, LOFs and indices.
///
/// Endpoint: https://hq.sinajs.cn/list=sh600519,sz159915
/// Response (GBK): `var hq_str_sh600519="贵州茅台,1700.00,1680.00,1690.00,...";`
///
/// Price fields are pure ASCII so numeric parsing is encoding-safe;
/// the Chinese name field is only best-effort (may be garbled).
class SinaSource extends MarketDataSource {
  SinaSource({http.Client? client}) : _client = client ?? http.Client(), super(MarketSource.sina);

  final http.Client _client;

  static const _base = 'https://hq.sinajs.cn/list=';

  @override
  Future<List<MarketQuote>> fetch(List<String> symbols) async {
    final results = <MarketQuote>[];
    // Sina accepts a large batch per request; chunk conservatively.
    for (final batch in MarketFetchHelper.chunk(symbols, 50)) {
      try {
        final resp = await _client.get(
          Uri.parse('$_base${batch.join(',')}'),
          headers: {'Referer': 'https://finance.sina.com.cn'},
        );
        if (resp.statusCode != 200) {
          results.addAll(batch.map((s) => MarketQuote.failure(s, source, 'HTTP ${resp.statusCode}')));
          continue;
        }
        // latin1 maps each raw byte 1:1, preserving all ASCII fields.
        final text = latin1.decode(resp.bodyBytes, allowInvalid: true);
        final quotes = _parse(text);
        for (final symbol in batch) {
          results.add(quotes[symbol] ?? MarketQuote.failure(symbol, source, '无行情'));
        }
      } catch (_) {
        results.addAll(batch.map((s) => MarketQuote.failure(s, source, '请求失败')));
      }
    }
    return results;
  }

  /// Parses `var hq_str_SYMBOL="...";` lines. Depends only on ASCII fields.
  Map<String, MarketQuote> _parse(String text) {
    final map = <String, MarketQuote>{};
    final regex = RegExp(r'var hq_str_(\w+)="(.*)";');
    for (final m in regex.allMatches(text)) {
      final symbol = m.group(1)!;
      final fields = m.group(2)!.split(',');
      if (fields.length < 32) continue;
      final price = double.tryParse(fields[3]) ?? 0;
      final prevClose = double.tryParse(fields[2]);
      if (price <= 0) continue;
      map[symbol] = MarketQuote(
        symbol: symbol,
        source: source,
        name: '',
        price: price,
        currency: 'CNY',
        prevClose: prevClose,
        change: prevClose == null ? null : price - prevClose,
        changePct: (prevClose == null || prevClose == 0) ? null : (price - prevClose) / prevClose,
        fetchedAt: DateTime.now(),
      );
    }
    return map;
  }
}
