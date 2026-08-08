import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import 'market_data_source.dart';

/// CoinGecko crypto prices (free tier, no API key).
///
/// Endpoint: https://api.coingecko.com/api/v3/simple/price
///   ?ids=bitcoin,ethereum&vs_currencies=cny&include_24hr_change=true
/// The `symbol` field for crypto holdings is the CoinGecko coin id,
/// e.g. `bitcoin`, `ethereum`, `tether`.
class CoinGeckoSource extends MarketDataSource {
  CoinGeckoSource({http.Client? client})
      : _client = client ?? http.Client(),
        super(MarketSource.coingecko);

  final http.Client _client;

  static const _base = 'https://api.coingecko.com/api/v3/simple/price';

  @override
  Future<List<MarketQuote>> fetch(List<String> symbols) async {
    final results = <MarketQuote>[];
    for (final batch in MarketFetchHelper.chunk(symbols, 50)) {
      try {
        final uri = Uri.parse(_base).replace(queryParameters: {
          'ids': batch.join(','),
          'vs_currencies': 'cny',
          'include_24hr_change': 'true',
        });
        final resp = await _client.get(uri);
        if (resp.statusCode != 200) {
          results.addAll(
              batch.map((s) => MarketQuote.failure(s, source, 'HTTP ${resp.statusCode}')));
          continue;
        }
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        for (final symbol in batch) {
          final coin = data[symbol];
          if (coin is Map<String, dynamic>) {
            final price = (coin['cny'] as num?)?.toDouble();
            final changePct = (coin['cny_24h_change'] as num?)?.toDouble();
            if (price == null || price <= 0) {
              results.add(MarketQuote.failure(symbol, source, '无行情'));
              continue;
            }
            results.add(MarketQuote(
              symbol: symbol,
              source: source,
              name: symbol,
              price: price,
              currency: 'CNY',
              prevClose: changePct == null ? null : price / (1 + changePct / 100),
              changePct: changePct,
              change: changePct == null
                  ? null
                  : price - price / (1 + changePct / 100),
              fetchedAt: DateTime.now(),
            ));
          } else {
            results.add(MarketQuote.failure(symbol, source, '未知币种'));
          }
        }
      } catch (_) {
        results.addAll(batch.map((s) => MarketQuote.failure(s, source, '请求失败')));
      }
    }
    return results;
  }
}
