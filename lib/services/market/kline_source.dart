import 'dart:convert';

import 'package:http/http.dart' as http;

import 'market_data_source.dart';

enum KlinePeriod { day, week, month }

typedef MarketIntraday = ({
  String date,
  double? previousClose,
  List<({int minute, double value})> points,
});

bool supportsMarketIntraday(String symbol) =>
    RegExp(r'^(?:(?:sh|sz|bj)\d{6}|hk\d{5})$').hasMatch(symbol);

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

  /// Tencent's latest dated minute series for mainland and HK securities.
  Future<MarketIntraday?> fetchIntraday(String symbol) async {
    if (!supportsMarketIntraday(symbol)) return null;
    final lastMinute = symbol.startsWith('hk') ? 960 : 900;
    for (final endpoint in const [
      'https://proxy.finance.qq.com/ifzqgtimg/appstock/app/minute/query',
      'https://web.ifzq.gtimg.cn/appstock/app/minute/query',
    ]) {
      try {
        final response = await _client
            .get(Uri.parse(endpoint).replace(queryParameters: {'code': symbol}))
            .timeout(marketHttpTimeout);
        if (response.statusCode != 200) continue;
        final root = jsonDecode(utf8.decode(response.bodyBytes));
        if (root is! Map || root['code'] != 0 || root['data'] is! Map) continue;
        final security = (root['data'] as Map)[symbol];
        if (security is! Map || security['data'] is! Map) continue;
        final minuteData = security['data'] as Map;
        final rawDate = minuteData['date'];
        final records = minuteData['data'];
        if (rawDate is! String ||
            !RegExp(r'^\d{8}$').hasMatch(rawDate) ||
            records is! List) {
          continue;
        }
        final date =
            '${rawDate.substring(0, 4)}-${rawDate.substring(4, 6)}-${rawDate.substring(6)}';
        if (DateTime.tryParse(date)?.toIso8601String().split('T').first !=
            date) {
          continue;
        }
        final prices = <int, double>{};
        for (final row in records) {
          if (row is! String) continue;
          final fields = row.trim().split(RegExp(r'\s+'));
          if (fields.length < 2 || !RegExp(r'^\d{4}$').hasMatch(fields.first)) {
            continue;
          }
          final time = fields.first;
          final minute = int.parse(time.substring(2));
          final minuteOfDay = int.parse(time.substring(0, 2)) * 60 + minute;
          final price = double.tryParse(fields[1]);
          if (minute >= 60 ||
              minuteOfDay < 570 ||
              minuteOfDay > lastMinute ||
              price == null ||
              !price.isFinite ||
              price <= 0) {
            continue;
          }
          prices[minuteOfDay] = price;
        }
        if (prices.isEmpty) continue;
        final quotes = security['qt'];
        final quote = quotes is Map ? quotes[symbol] : null;
        // The embedded Tencent quote uses the same field order as qt.gtimg.cn.
        final previousClose = quote is List && quote.length > 4
            ? double.tryParse(quote[4].toString())
            : null;
        final minutes = prices.keys.toList()..sort();
        return (
          date: date,
          previousClose:
              previousClose != null &&
                  previousClose.isFinite &&
                  previousClose > 0
              ? previousClose
              : null,
          points: [for (final m in minutes) (minute: m, value: prices[m]!)],
        );
      } catch (_) {
        // Try the alternate host after a failed or malformed response.
      }
    }
    return null;
  }

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
