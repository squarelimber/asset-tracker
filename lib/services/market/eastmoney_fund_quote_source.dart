import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import 'market_data_source.dart';

/// Eastmoney (天天基金) mutual-fund NAV quotes.
///
/// Endpoint: `https://fundmobapi.eastmoney.com/FundMNewApi/FundMNFInfo`
/// — the fund-only mobile API behind 天天基金's own app. It answers with
/// `Datas[] = {FCODE, SHORTNAME (fund name), PDATE (NAV date), NAV (unit
/// NAV), NAVCHGRT (daily change %)},` accepts comma-separated `FCODES`,
/// and sends `Access-Control-Allow-Origin: *`, so it serves both the web
/// build (no Referer tricks needed) and the native fallback path.
///
/// ⚠️ Why not push2? This source used to ask
/// `push2.eastmoney.com/api/qt/stock/get?secid=0.{code}` — the *stock*
/// endpoint. Off-exchange fund codes and third-board (老三板/新三板) stock
/// codes occupy the same 6-digit namespace, so 400030 ("东方添益债券",
/// NAV 1.4553) was answered with the unrelated third-board stock "蓝璟5"
/// trading at 0.063: a 23x error that MarketService wrote straight into the
/// holding, fabricating a −99,286.04 loss on the earnings calendar. A
/// fund-only endpoint cannot collide like that — it does not know the stock
/// market exists.
class EastmoneyFundQuoteSource extends MarketDataSource {
  EastmoneyFundQuoteSource({http.Client? client})
      : _client = client ?? http.Client(),
        super(MarketSource.eastmoney);

  final http.Client _client;

  static const _base =
      'https://fundmobapi.eastmoney.com/FundMNewApi/FundMNFInfo';

  /// Static client identity the mobile API expects; it validates neither
  /// the value nor a signature, but it does require the parameters.
  static const _clientQuery = 'deviceid=Wap&plat=Wap&product=EFund&version=2.0.0';

  @override
  Future<List<MarketQuote>> fetch(List<String> symbols) async {
    final results = <MarketQuote>[];
    // The API is batch-capable; chunk to keep URLs short.
    for (final batch in MarketFetchHelper.chunk(symbols, 40)) {
      results.addAll(await _fetchBatch(batch));
    }
    return results;
  }

  Future<List<MarketQuote>> _fetchBatch(List<String> symbols) async {
    final requested = symbols.toList();
    try {
      final codes = requested.map(Uri.encodeComponent).join(',');
      final resp = await _client
          .get(Uri.parse('$_base?FCODES=$codes&$_clientQuery'))
          .timeout(marketHttpTimeout);
      if (resp.statusCode != 200) {
        return requested
            .map((s) => MarketQuote.failure(s, source, 'HTTP ${resp.statusCode}'))
            .toList();
      }
      final json =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final rows = json['Datas'] as List?;
      final byCode = <String, Map<String, dynamic>>{};
      for (final row in rows ?? const []) {
        final map = row as Map<String, dynamic>;
        final code = map['FCODE']?.toString();
        // The API answers unknown codes with Datas: null; guard anyway so a
        // partial payload can never shift a quote onto the wrong holding.
        if (code != null && code.isNotEmpty) byCode[code] = map;
      }
      return requested
          .map((s) => _parse(s, byCode[s]))
          .toList(growable: false);
    } catch (_) {
      return requested
          .map((s) => MarketQuote.failure(s, source, '请求失败'))
          .toList();
    }
  }

  static MarketQuote _parse(String symbol, Map<String, dynamic>? row) {
    if (row == null) {
      return MarketQuote.failure(symbol, MarketSource.eastmoney, '无此基金净值');
    }
    final nav = double.tryParse(row['NAV']?.toString() ?? '');
    if (nav == null || nav <= 0) {
      return MarketQuote.failure(symbol, MarketSource.eastmoney, '净值异常');
    }
    final changePct = double.tryParse(row['NAVCHGRT']?.toString() ?? '');
    final prev = (changePct == null || changePct == 0)
        ? null
        : nav / (1 + changePct / 100);
    return MarketQuote(
      symbol: symbol,
      source: MarketSource.eastmoney,
      name: row['SHORTNAME']?.toString() ?? '',
      price: nav,
      currency: 'CNY',
      prevClose: prev,
      change: prev == null ? null : nav - prev,
      changePct: changePct == null ? null : changePct / 100,
      fetchedAt: DateTime.now(),
    );
  }
}
