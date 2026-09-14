import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import '../../core/gold.dart';
import 'market_data_source.dart';

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
      final resp = await _client
          .get(Uri.parse('$_base$symbol.js'),
              headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
          .timeout(marketHttpTimeout);
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
      final resp = await _client.get(uri).timeout(marketHttpTimeout);
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

/// London spot gold (XAU) converted into CNY per gram — the historical
/// counterpart of the live gold quote.
///
/// Both numbers must come from the same instrument. The live gold quote is
/// London spot (`hf_XAU`, USD/oz) x USDCNY / 31.1034768, but this source
/// used to return the Shanghai gold *futures* continuous contract
/// (AU0, CNY/gram). Those are two different markets trading at a ~1%
/// basis, and because "today" is written by the live path while every
/// earlier day is derived from this series, the basis landed entirely on
/// today: a fake several-hundred-yuan daily return that vanished as soon as
/// the next rebuild re-derived the day from the other instrument. Deriving
/// the series from London spot through the shared [goldCnyPerGram] removes
/// the second instrument (and the second formula) altogether.
///
/// Endpoints:
/// - gold closes: `GlobalFuturesService.getGlobalFuturesDailyKLine`
///   (`symbol=XAU`, USD per troy ounce, full history in one request)
/// - USD/CNY closes: `NewForexService.getDayKLine` (`symbol=fx_susdcny`)
///
/// Gold and FX do not share a calendar (gold trades on days the FX market is
/// closed and vice versa), so each gold day is paired with the latest FX
/// rate published on or before it instead of requiring both series to carry
/// the exact day.
class XauGoldHistorySource extends HistoryDataSource {
  XauGoldHistorySource({http.Client? client})
      : _client = client ?? http.Client(),
        super(MarketSource.sge);

  final http.Client _client;

  static const _goldBase =
      'https://stock.finance.sina.com.cn/futures/api/jsonp.php/var%20_=/GlobalFuturesService.getGlobalFuturesDailyKLine';

  static const _fxBase =
      'https://vip.stock.finance.sina.com.cn/forex/api/jsonp.php/var%20_=/NewForexService.getDayKLine';

  static const _headers = {
    'Referer': 'https://finance.sina.com.cn',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
  };

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    final result = <String, double>{};
    try {
      final gold = await _fetchGoldClose();
      if (gold.isEmpty) return result;
      final fx = await _fetchUsdCnyClose();
      if (fx.isEmpty) return result;
      final fxDates = fx.keys.toList()..sort();
      final fromKey = _key(from);
      final toKey = _key(to);
      for (final entry in gold.entries) {
        final date = entry.key;
        if (date.compareTo(fromKey) < 0 || date.compareTo(toKey) > 0) continue;
        final rate = _rateOnOrBefore(fx, fxDates, date);
        if (rate == null || rate <= 0) continue;
        result[date] = goldCnyPerGram(entry.value, rate);
      }
    } catch (_) {
      // Return what we have.
    }
    return result;
  }

  /// Daily London gold closes (USD per troy ounce) keyed by yyyy-MM-dd.
  Future<Map<String, double>> _fetchGoldClose() async {
    final out = <String, double>{};
    final uri = Uri.parse(_goldBase).replace(queryParameters: {'symbol': 'XAU'});
    final resp = await _client.get(uri, headers: _headers).timeout(marketHttpTimeout);
    if (resp.statusCode != 200) return out;
    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start < 0 || end <= start) return out;
    final list = jsonDecode(text.substring(start, end + 1)) as List;
    for (final item in list) {
      final map = item as Map<String, dynamic>;
      final date = map['date']?.toString() ?? '';
      final close = double.tryParse(map['close']?.toString() ?? '');
      if (date.isNotEmpty && close != null && close > 0) out[date] = close;
    }
    return out;
  }

  /// Daily USD/CNY closes keyed by yyyy-MM-dd. The payload is a
  /// `"date,open,high,low,close,|..."` string, so it is scanned row-wise
  /// rather than parsed as JSON.
  Future<Map<String, double>> _fetchUsdCnyClose() async {
    final out = <String, double>{};
    final uri = Uri.parse(_fxBase).replace(queryParameters: {'symbol': 'fx_susdcny'});
    final resp = await _client.get(uri, headers: _headers).timeout(marketHttpTimeout);
    if (resp.statusCode != 200) return out;
    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final row = RegExp(r'(\d{4}-\d{2}-\d{2}),([\d.]+),([\d.]+),([\d.]+),([\d.]+)');
    for (final m in row.allMatches(text)) {
      final close = double.tryParse(m.group(5)!);
      if (close != null && close > 0) out[m.group(1)!] = close;
    }
    return out;
  }

  /// Latest rate published on or before [date] (binary search over sorted
  /// [dates]); null when [date] predates the whole series.
  static double? _rateOnOrBefore(
    Map<String, double> rates,
    List<String> dates,
    String date,
  ) {
    var lo = 0;
    var hi = dates.length - 1;
    var best = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (dates[mid].compareTo(date) <= 0) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best < 0 ? null : rates[dates[best]];
  }

  static String _key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
