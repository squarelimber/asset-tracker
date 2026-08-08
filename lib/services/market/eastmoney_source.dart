import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import 'market_data_source.dart';

/// Eastmoney (天天基金) source for off-exchange mutual funds.
///
/// Official NAV endpoint:
/// https://api.fund.eastmoney.com/f10/lsjz?fundCode={code}&pageIndex=1&pageSize=1
/// Requires `Referer: http://fundf10.eastmoney.com/`.
/// Returns the latest official NAV (DWJZ) and daily change (JZZZL).
class EastmoneySource extends MarketDataSource {
  EastmoneySource({http.Client? client})
      : _client = client ?? http.Client(),
        super(MarketSource.eastmoney);

  final http.Client _client;

  static const _base = 'https://api.fund.eastmoney.com/f10/lsjz';

  @override
  Future<List<MarketQuote>> fetch(List<String> symbols) async {
    final results = <MarketQuote>[];
    // One request per fund; fetch concurrently but bounded.
    for (final batch in MarketFetchHelper.chunk(symbols, 20)) {
      final futures = <Future<MarketQuote>>[];
      for (final symbol in batch) {
        futures.add(_fetchOne(symbol));
      }
      results.addAll(await Future.wait(futures));
    }
    return results;
  }

  Future<MarketQuote> _fetchOne(String symbol) async {
    try {
      final uri = Uri.parse(_base).replace(queryParameters: {
        'fundCode': symbol,
        'pageIndex': '1',
        'pageSize': '1',
      });
      final resp = await _client.get(uri, headers: {
        'Referer': 'http://fundf10.eastmoney.com/',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
      });
      if (resp.statusCode != 200) {
        return MarketQuote.failure(symbol, source, 'HTTP ${resp.statusCode}');
      }
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final navList = (data['Data']?['LSJZList'] ?? []) as List;
      if (navList.isEmpty) {
        return MarketQuote.failure(symbol, source, '无净值');
      }
      final item = navList.first as Map<String, dynamic>;
      final nav = double.tryParse(item['DWJZ']?.toString() ?? '');
      final changePct = double.tryParse(item['JZZZL']?.toString() ?? '');
      if (nav == null || nav <= 0) {
        return MarketQuote.failure(symbol, source, '净值异常');
      }
      final prev = (changePct == null || changePct == 0)
          ? null
          : nav / (1 + changePct / 100);
      return MarketQuote(
        symbol: symbol,
        source: source,
        name: '',
        price: nav,
        currency: 'CNY',
        prevClose: prev,
        change: prev == null ? null : nav - prev,
        changePct: changePct == null ? null : changePct / 100,
        fetchedAt: DateTime.now(),
      );
    } catch (_) {
      return MarketQuote.failure(symbol, source, '请求失败');
    }
  }
}
