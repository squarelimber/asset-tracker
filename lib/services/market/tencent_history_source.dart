import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import 'history_source.dart';
import 'market_data_source.dart';

/// Tencent K-line history (web.ifzq.gtimg.cn) — CORS-friendly
/// (`Access-Control-Allow-Origin: *`) replacement for the Sina K-line
/// endpoints on the web.
///
/// Symbols: sh/sz A-shares and indices, hk* (Hang Seng etc.), us* (US
/// indices), wh*CNY FX. Response rows are
/// `["date","open","close","high","low","volume",...]` under
/// `data.{symbol}.qfqday` (or `.day` for FX).
class TencentHistorySource extends HistoryDataSource {
  TencentHistorySource({http.Client? client})
      : _client = client ?? http.Client(),
        super(MarketSource.sina);

  final http.Client _client;

  static const _base = 'https://web.ifzq.gtimg.cn/appstock/app/fqkline/get';

  /// Max rows per request accepted by the endpoint.
  static const _maxRows = 800;

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    final result = <String, double>{};
    final fromKey = _key(from);
    final toKey = _key(to);
    try {
      final days = to.difference(from).inDays + 20;
      if (days <= _maxRows) {
        _collect(await _request(symbol, from, to, days), result, fromKey, toKey);
      } else {
        // Split into two windows so each request stays under the row cap.
        final mid = to.subtract(Duration(days: days ~/ 2));
        _collect(await _request(symbol, mid, to, _maxRows), result, fromKey, toKey);
        _collect(await _request(symbol, from, mid, _maxRows), result, fromKey, toKey);
      }
    } catch (_) {
      // Return what we have.
    }
    return result;
  }

  Future<List<List<dynamic>>> _request(
    String symbol,
    DateTime from,
    DateTime to,
    int count,
  ) async {
    final uri = Uri.parse(_base).replace(queryParameters: {
      'param': '$symbol,day,${_key(from)},${_key(to)},$count,qfq',
    });
    final resp = await _client.get(uri).timeout(marketHttpTimeout);
    if (resp.statusCode != 200) return const [];
    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final data = json['data']?[symbol] as Map<String, dynamic>?;
    if (data == null) return const [];
    return ((data['qfqday'] ?? data['day'] ?? const []) as List)
        .cast<List<dynamic>>();
  }

  void _collect(
    List<List<dynamic>> rows,
    Map<String, double> result,
    String fromKey,
    String toKey,
  ) {
    for (final row in rows) {
      if (row.length < 3) continue;
      final date = row[0].toString();
      if (date.compareTo(fromKey) < 0 || date.compareTo(toKey) > 0) continue;
      final close = double.tryParse(row[2].toString());
      if (close != null && close > 0) result[date] = close;
    }
  }

  static String _key(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }
}
