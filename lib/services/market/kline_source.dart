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

  /// Fetch adjusted prices by default. Raw prices use the provider's `bfq`
  /// mode so recorded, unadjusted transaction prices can be charted directly.
  Future<List<CandleBar>> fetch(
    String symbol,
    KlinePeriod period, {
    bool adjusted = true,
  }) async {
    final resolvedSymbol = await _resolveHistorySymbol(symbol);
    if (resolvedSymbol == null) return const [];
    final periodName = period.name;
    for (final endpoint in _endpoints) {
      try {
        final uri = Uri.parse(endpoint).replace(
          queryParameters: {
            'param':
                '$resolvedSymbol,$periodName,,,300,${adjusted ? 'qfq' : 'bfq'}',
          },
        );
        final response = await _client.get(uri).timeout(marketHttpTimeout);
        if (response.statusCode != 200) continue;
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body is! Map || body['code'] != 0 || body['data'] is! Map) continue;
        final data = (body['data'] as Map)[resolvedSymbol];
        if (data is! Map) continue;
        final rows = adjusted
            ? data['qfq$periodName'] ?? data[periodName]
            : data[periodName];
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

  /// Tencent's US historical endpoint needs an exchange suffix, even when
  /// its quote endpoint accepts a bare ticker. Resolve it from the provider's
  /// quote rather than guessing an exchange or displaying a partial series.
  Future<String?> _resolveHistorySymbol(String symbol) async {
    if (!symbol.startsWith('us')) return symbol;
    final ticker = symbol.substring(2);
    if (RegExp(
      r'\.(?:OQ|N|AM|PK|OB|PS)$',
      caseSensitive: false,
    ).hasMatch(ticker)) {
      return symbol;
    }
    try {
      final response = await _client
          .get(Uri.https('qt.gtimg.cn', '/q=$symbol'))
          .timeout(marketHttpTimeout);
      if (response.statusCode != 200) return null;
      final text = latin1.decode(response.bodyBytes, allowInvalid: true);
      final match = RegExp(
        'v_${RegExp.escape(symbol)}="([^"]*)"',
      ).firstMatch(text);
      if (match == null) return null;
      final fields = match.group(1)!.split('~');
      if (fields.length < 3) return null;
      final resolved = fields[2].trim().toUpperCase();
      final prefix = '${ticker.toUpperCase()}.';
      if (!resolved.startsWith(prefix) ||
          !RegExp(r'^[A-Z0-9.\-]+$').hasMatch(resolved) ||
          resolved.length <= prefix.length) {
        return null;
      }
      return 'us$resolved';
    } catch (_) {
      return null;
    }
  }
}
