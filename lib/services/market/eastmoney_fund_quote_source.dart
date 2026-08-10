import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import 'market_data_source.dart';

/// Eastmoney mutual-fund NAV via the push2 endpoint — CORS-friendly
/// replacement for api.fund.eastmoney.com on the web.
///
/// Endpoint: `https://push2.eastmoney.com/api/qt/stock/get?secid=0.{code}`
/// Response `data`: f43 = latest NAV x1000, f169 = daily change x1000,
/// f170 = daily change % x100, f58 = fund name (UTF-8).
class EastmoneyFundQuoteSource extends MarketDataSource {
  EastmoneyFundQuoteSource({http.Client? client})
      : _client = client ?? http.Client(),
        super(MarketSource.eastmoney);

  final http.Client _client;

  static const _base = 'https://push2.eastmoney.com/api/qt/stock/get';

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
        'secid': '0.$symbol',
        'fields': 'f43,f57,f58,f169,f170',
      });
      final resp = await _client.get(uri);
      if (resp.statusCode != 200) {
        return MarketQuote.failure(symbol, source, 'HTTP ${resp.statusCode}');
      }
      final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final data = json['data'] as Map<String, dynamic>?;
      if (data == null || data['f43'] == null) {
        return MarketQuote.failure(symbol, source, '无净值');
      }
      final nav = (data['f43'] as num).toDouble() / 1000;
      if (nav <= 0) return MarketQuote.failure(symbol, source, '净值异常');
      final change = (data['f169'] as num?)?.toDouble() ?? 0;
      final changePct = (data['f170'] as num?)?.toDouble() ?? 0;
      final prev = change == 0 ? null : nav - change / 1000;
      return MarketQuote(
        symbol: symbol,
        source: source,
        name: data['f58']?.toString() ?? '',
        price: nav,
        currency: 'CNY',
        prevClose: prev,
        change: prev == null ? null : nav - prev,
        changePct: changePct == 0 ? null : changePct / 10000,
        fetchedAt: DateTime.now(),
      );
    } catch (_) {
      return MarketQuote.failure(symbol, source, '请求失败');
    }
  }
}
