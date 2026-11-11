import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/bse_code_mapping.dart';
import 'market_data_source.dart';

/// A security returned by the market search provider.
class SecuritySearchResult {
  const SecuritySearchResult({
    required this.symbol,
    required this.code,
    required this.name,
    required this.market,
    required this.type,
  });

  /// Provider symbol for the historical quote endpoint, including exchange.
  final String symbol;
  final String code;
  final String name;
  final String market;
  final String type;
}

class SecuritySearchException implements Exception {
  const SecuritySearchException();
}

/// Search Tencent's A-share, Hong Kong and US securities catalog.
/// Its JSON endpoint allows cross-origin requests in the web application.
class SecuritySearchSource {
  SecuritySearchSource({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  static final Uri _endpoint = Uri.parse(
    'https://proxy.finance.qq.com/ifzqgtimg/appstock/smartbox/search/get',
  );

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<List<SecuritySearchResult>> search(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];
    try {
      final response = await _client
          .get(_endpoint.replace(queryParameters: {'q': keyword}))
          .timeout(marketHttpTimeout);
      if (response.statusCode != 200) throw const SecuritySearchException();
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map || body['code'] != 0 || body['data'] is! Map) {
        throw const SecuritySearchException();
      }
      final rows = (body['data'] as Map)['stock'];
      if (rows is! List) throw const SecuritySearchException();

      final results = <SecuritySearchResult>[];
      final seen = <String>{};
      for (final row in rows) {
        if (row is! List || row.length < 5) continue;
        final exchange = row[0].toString().toLowerCase();
        var code = row[1].toString().trim();
        final name = row[2].toString().trim();
        final category = row[4].toString().toUpperCase();
        final isEtf =
            category.contains('ETF') ||
            (exchange == 'hk' && category == 'GP-FUND');
        if (name.isEmpty ||
            (!category.startsWith('GP') && !isEtf) ||
            category.contains('REITS')) {
          continue;
        }
        final String market;
        final String symbol;
        // The provider may return retired codes whose quote history has ended.
        // Only the exchange's published mapping can establish the successor.
        if (exchange == 'bj' && !code.startsWith('92')) {
          final currentCode = bseLegacyCodeMapping[code];
          if (currentCode == null) continue;
          code = currentCode;
        }
        if (const {'sh', 'sz', 'bj'}.contains(exchange) &&
            RegExp(r'^\d{6}$').hasMatch(code)) {
          market = 'A股';
          symbol = '$exchange$code';
        } else if (exchange == 'hk' && RegExp(r'^\d{5}$').hasMatch(code)) {
          market = '港股';
          symbol = 'hk$code';
        } else if (exchange == 'us' &&
            RegExp(r'^[A-Za-z0-9][A-Za-z0-9.\-]*$').hasMatch(code)) {
          market = '美股';
          // The search provider's suffix identifies the exchange and must
          // be retained: usAAPL and usAAPL.OQ are distinct historical feeds.
          symbol = 'us${code.toUpperCase()}';
        } else {
          continue;
        }
        if (seen.add(symbol)) {
          results.add(
            SecuritySearchResult(
              symbol: symbol,
              code: code,
              name: name,
              market: market,
              type: isEtf ? 'ETF' : '股票',
            ),
          );
        }
      }
      return results;
    } catch (_) {
      throw const SecuritySearchException();
    }
  }
}
