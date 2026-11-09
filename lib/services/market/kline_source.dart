import 'dart:convert';

import 'package:http/http.dart' as http;

import 'market_data_source.dart';

enum KlinePeriod { day, week, month }

class CandleBar {
  const CandleBar({
    required this.date,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  final DateTime date;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
}

/// Tencent OHLCV history. The proxy endpoint supports browser CORS.
class KlineSource {
  KlineSource({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) _client.close();
  }

  static const _endpoints = [
    'https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get',
    'https://ifzq.gtimg.cn/appstock/app/fqkline/get',
    'https://web.ifzq.gtimg.cn/appstock/app/fqkline/get',
  ];

  Future<List<CandleBar>> fetch(String symbol, KlinePeriod period) async {
    final periodName = period.name;
    for (final endpoint in _endpoints) {
      try {
        final uri = Uri.parse(
          endpoint,
        ).replace(queryParameters: {'param': '$symbol,$periodName,,,300,qfq'});
        final response = await _client.get(uri).timeout(marketHttpTimeout);
        if (response.statusCode != 200) continue;
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body is! Map || body['code'] != 0 || body['data'] is! Map) continue;
        final data = (body['data'] as Map)[symbol];
        if (data is! Map) continue;
        final rows = data['qfq$periodName'] ?? data[periodName];
        if (rows is! List) continue;
        final barsByDate = <DateTime, CandleBar>{};
        for (final row in rows) {
          if (row is! List || row.length < 6) continue;
          final date = DateTime.tryParse(row[0].toString());
          final open = double.tryParse(row[1].toString());
          final close = double.tryParse(row[2].toString());
          final high = double.tryParse(row[3].toString());
          final low = double.tryParse(row[4].toString());
          final volume = double.tryParse(row[5].toString());
          if (date == null ||
              open == null ||
              !open.isFinite ||
              open <= 0 ||
              close == null ||
              !close.isFinite ||
              close <= 0 ||
              high == null ||
              !high.isFinite ||
              high <= 0 ||
              low == null ||
              !low.isFinite ||
              low <= 0 ||
              high < open ||
              high < close ||
              high < low ||
              low > open ||
              low > close ||
              volume == null ||
              !volume.isFinite ||
              volume < 0) {
            continue;
          }
          barsByDate[date] = CandleBar(
            date: date,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: volume,
          );
        }
        if (barsByDate.isNotEmpty) {
          final bars = barsByDate.values.toList()
            ..sort((a, b) => a.date.compareTo(b.date));
          return bars;
        }
      } catch (_) {
        // Continue to the next endpoint on transport or malformed data.
      }
    }
    return const [];
  }
}
