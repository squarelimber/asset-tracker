import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import 'history_source.dart';
import 'market_data_source.dart';

/// Tencent K-line history (the `proxy.finance.qq.com` / `ifzq.gtimg.cn`
/// gateways) — CORS-friendly replacement for the Sina K-line endpoints on
/// the web.
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

  /// Full endpoint URLs, tried in order. The path differs between the
  /// `proxy.finance.qq.com` gateway (`/ifzqgtimg/appstock/app/newfqkline/get`)
  /// and the legacy `*.ifzq.gtimg.cn` hosts (`/appstock/app/fqkline/get`), so
  /// the whole URL is carried here rather than just a host to swap out.
  ///
  /// `web.ifzq.gtimg.cn` began answering a WAF `501` (a JS challenge page,
  /// no data) around 2026-10-08, which is why the bare `ifzq.gtimg.cn` host
  /// became the primary one. By 2026-10-09 the WAF had caught up with that
  /// host too and *both* returned 501 — reproduced direct and through a
  /// proxy, with a browser UA and a Referer, on every `param` spelling, while
  /// `qt.gtimg.cn` quotes and the Eastmoney fund NAV endpoint stayed 200. The
  /// `proxy.finance.qq.com` gateway still serves the same qfq-adjusted
  /// `qfqday` payload, so it is queried first; the two dead hosts sit at the
  /// end to keep the feature alive if the WAF rule moves again.
  ///
  /// This is not cosmetic: a 501 comes back as an *empty* series, which the
  /// backfill used to accept as "no data" and then price every historical
  /// day of that holding with the current quote — the 2026-10-08
  /// 「今天的收益被算到 10-05」 bug.
  static const _endpoints = [
    'https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get',
    'https://ifzq.gtimg.cn/appstock/app/fqkline/get',
    'https://web.ifzq.gtimg.cn/appstock/app/fqkline/get',
  ];

  static const _headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://gu.qq.com/',
  };

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

  /// Rows for [symbol] in [from]..[to]. The endpoints are tried in order, but
  /// only when the request itself failed (transport error or non-200): a
  /// well-formed response is taken at face value even when it carries no
  /// rows, because a symbol can legitimately have no bars in the window.
  Future<List<List<dynamic>>> _request(
    String symbol,
    DateTime from,
    DateTime to,
    int count,
  ) async {
    for (final base in _endpoints) {
      final rows = await _requestFrom(base, symbol, from, to, count);
      if (rows != null) return rows;
    }
    return const [];
  }

  /// Rows from [base], or null when the request did not yield a usable
  /// payload (so the caller can try the next host).
  Future<List<List<dynamic>>?> _requestFrom(
    String base,
    String symbol,
    DateTime from,
    DateTime to,
    int count,
  ) async {
    try {
      final uri = Uri.parse(base).replace(queryParameters: {
        'param': '$symbol,day,${_key(from)},${_key(to)},$count,qfq',
      });
      final resp =
          await _client.get(uri, headers: _headers).timeout(marketHttpTimeout);
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final data = json['data']?[symbol] as Map<String, dynamic>?;
      if (data == null) return null;
      return ((data['qfqday'] ?? data['day'] ?? const []) as List)
          .cast<List<dynamic>>();
    } catch (_) {
      return null;
    }
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
