import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';

/// Daily close price history: date (yyyy-MM-dd) -> close price.
typedef DailyPriceHistory = Map<String, double>;

/// A source of historical daily prices for backfilling the net worth chart.
abstract class HistoryDataSource {
  HistoryDataSource(this.source);

  final MarketSource source;

  /// Fetches daily prices from [from] (inclusive) to [to] (inclusive).
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to);
}

/// Eastmoney mutual fund NAV history.
/// Endpoint: https://fund.eastmoney.com/pingzhongdata/{code}.js
/// Contains `var Data_netWorthTrend = [{"x":<ms>,"y":<nav>,...}];` with the
/// full NAV history in one request.
class EastmoneyHistorySource extends HistoryDataSource {
  EastmoneyHistorySource({http.Client? client})
      : _client = client ?? http.Client(),
        super(MarketSource.eastmoney);

  final http.Client _client;

  static const _base = 'https://fund.eastmoney.com/pingzhongdata/';

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    final result = <String, double>{};
    try {
      final resp = await _client.get(
        Uri.parse('$_base$symbol.js'),
        headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
      );
      if (resp.statusCode != 200) return result;
      final text = utf8.decode(resp.bodyBytes);
      final match = RegExp(r'var Data_netWorthTrend = (\[.*?\]);').firstMatch(text);
      if (match == null) return result;
      final list = jsonDecode(match.group(1)!) as List;
      final fromKey = _key(from);
      final toKey = _key(to);
      for (final item in list) {
        final map = item as Map<String, dynamic>;
        final ms = (map['x'] as num?)?.toInt();
        final nav = (map['y'] as num?)?.toDouble();
        if (ms == null || nav == null || nav <= 0) continue;
        final date = _key(DateTime.fromMillisecondsSinceEpoch(ms));
        if (date.compareTo(fromKey) < 0 || date.compareTo(toKey) > 0) continue;
        result[date] = nav;
      }
    } catch (_) {
      // Return what we have.
    }
    return result;
  }

  static String _key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Sina A-share / ETF daily K-line history (CNY).
/// Endpoint: quotes.sina.cn getKLineData (scale=240 daily, datalen up to ~1000)
class SinaKLineSource extends HistoryDataSource {
  SinaKLineSource({http.Client? client})
      : _client = client ?? http.Client(),
        super(MarketSource.sina);

  final http.Client _client;

  static const _base =
      'https://quotes.sina.cn/cn/api/jsonp_v2.php/var%20_=/CN_MarketDataService.getKLineData';

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    final result = <String, double>{};
    try {
      final uri = Uri.parse(_base).replace(queryParameters: {
        'symbol': symbol,
        'scale': '240',
        'ma': 'no',
        'datalen': '1000',
      });
      final resp = await _client.get(uri);
      if (resp.statusCode != 200) return result;
      final text = utf8.decode(resp.bodyBytes);
      final start = text.indexOf('[');
      final end = text.lastIndexOf(']');
      if (start < 0 || end <= start) return result;
      final list = jsonDecode(text.substring(start, end + 1)) as List;
      for (final item in list) {
        final map = item as Map<String, dynamic>;
        final date = map['day']?.toString() ?? '';
        final close = double.tryParse(map['close']?.toString() ?? '');
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

/// Shanghai gold futures (AU0, CNY per gram) for gold accumulation history.
/// Endpoint: stock2.finance.sina.com.cn InnerFuturesNewService.getDailyKLine
class AuGoldHistorySource extends HistoryDataSource {
  AuGoldHistorySource({http.Client? client})
      : _client = client ?? http.Client(),
        super(MarketSource.sge);

  final http.Client _client;

  static const _base =
      'https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20_=/InnerFuturesNewService.getDailyKLine';

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    final result = <String, double>{};
    try {
      final uri = Uri.parse(_base).replace(queryParameters: {'symbol': 'AU0'});
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
