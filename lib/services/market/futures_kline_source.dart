import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import 'history_source.dart';

/// Domestic futures daily K-line (for commodity trend charts).
/// Endpoint: stock2.finance.sina.com.cn InnerFuturesNewService.getDailyKLine
/// Symbols: AU0 (沪金, 元/克), SC0 (沪油, 元/桶), CU0 (沪铜, 元/吨).
class FuturesKLineSource extends HistoryDataSource {
  FuturesKLineSource({http.Client? client})
      : _client = client ?? http.Client(),
        super(MarketSource.sge);

  final http.Client _client;

  static const _base =
      'https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20_=/InnerFuturesNewService.getDailyKLine';

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    final result = <String, double>{};
    try {
      final uri = Uri.parse(_base).replace(queryParameters: {'symbol': symbol});
      final resp = await _client.get(uri);
      if (resp.statusCode != 200) return result;
      final text = utf8.decode(resp.bodyBytes);
      final start = text.indexOf('[');
      final end = text.lastIndexOf(']');
      if (start < 0 || end <= start) return result;
      final list = jsonDecode(text.substring(start, end + 1)) as List;
      for (final item in list) {
        final map = item as Map<String, dynamic>;
        final date = map['d']?.toString() ?? '';
        final close = double.tryParse(map['c']?.toString() ?? '');
        if (date.isNotEmpty && close != null && close > 0) {
          result[date] = close;
        }
      }
    } catch (_) {
      // Return what we have.
    }
    return result;
  }
}
