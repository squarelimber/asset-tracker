import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import 'market_data_source.dart';

/// Gold (XAU) and FX rates via Sina Finance.
///
/// - Gold: `hf_XAU` London spot gold (USD/oz), converted to CNY/gram:
///   price_cny_per_gram = usd_per_oz * usdcny / 31.1034768
/// - FX: `fx_s{ccy}cny` cross rates (1 ccy = x CNY).
class GoldFxSource extends MarketDataSource {
  GoldFxSource({http.Client? client}) : _client = client ?? http.Client(), super(MarketSource.forex);

  final http.Client _client;

  static const _base = 'https://hq.sinajs.cn/list=';

  /// Aliases accepted for gold holdings.
  static const _goldAliases = {'XAU', 'AU99.99', 'AU9999', 'GOLD'};

  /// Supported currency codes -> Sina FX symbol.
  static const _fxSymbols = {
    'USD': 'fx_susdcny',
    'EUR': 'fx_seurcny',
    'HKD': 'fx_shkdcny',
    'GBP': 'fx_sgbpcny',
    'AUD': 'fx_saudcny',
    'CAD': 'fx_scadcny',
    'JPY': 'fx_sjpycny',
    'CHF': 'fx_schfcny',
  };

  static const _ozToGram = 31.1034768;

  @override
  Future<List<MarketQuote>> fetch(List<String> symbols) async {
    final golds = symbols.where((s) => _goldAliases.contains(s.toUpperCase())).toList();
    final fx = symbols
        .where((s) => _fxSymbols.containsKey(s.toUpperCase()))
        .map((s) => s.toUpperCase())
        .toList();

    final results = <MarketQuote>[];
    final goldFutures = golds.map((g) => _fetchGold(g)).toList();
    results.addAll(await Future.wait(goldFutures));

    if (fx.isNotEmpty) {
      results.addAll(await _fetchFx(fx));
    }

    // Unknown symbols -> failure.
    final covered = {...golds.map((g) => g.toUpperCase()), ...fx};
    for (final s in symbols) {
      if (!covered.contains(s.toUpperCase())) {
        results.add(MarketQuote.failure(s, source, '不支持的代码'));
      }
    }
    return results;
  }

  Future<MarketQuote> _fetchGold(String symbol) async {
    final rate = await _fetchOne(_fxSymbols['USD']!);
    if (rate == null || rate.length <= 3) return MarketQuote.failure(symbol, source, '汇率不可用');
    final xau = await _fetchOne('hf_XAU');
    if (xau == null || xau.isEmpty) return MarketQuote.failure(symbol, source, '金价不可用');
    final usdPerOz = xau[0];
    if (usdPerOz <= 0) return MarketQuote.failure(symbol, source, '金价异常');
    final cnyPerGram = usdPerOz * rate[3] / _ozToGram;
    final prevCny = xau.length > 1 && xau[1] > 0 ? xau[1] * rate[3] / _ozToGram : null;
    return MarketQuote(
      symbol: symbol.toUpperCase(),
      source: source,
      name: '黄金 (Au99.99)',
      price: cnyPerGram,
      currency: 'CNY',
      prevClose: prevCny,
      change: prevCny == null ? null : cnyPerGram - prevCny,
      changePct: prevCny == null || prevCny == 0 ? null : (cnyPerGram - prevCny) / prevCny,
      fetchedAt: DateTime.now(),
    );
  }

  Future<List<MarketQuote>> _fetchFx(List<String> currencies) async {
    final codes = currencies.map((c) => _fxSymbols[c]!).toList();
    final quotes = <MarketQuote>[];
    try {
      final text = await _fetchRaw(codes);
      final parsed = _parse(text);
      for (final c in currencies) {
        final q = parsed[_fxSymbols[c]];
        if (q == null) {
          quotes.add(MarketQuote.failure(c, source, '无行情'));
        } else {
          final rate = q.length > 3 ? q[3] : 0.0;
          final prev = q.length > 7 ? q[7] : 0.0;
          quotes.add(
            MarketQuote(
              symbol: c,
              source: source,
              name: 'CNY/$c',
              price: rate,
              currency: 'CNY',
              prevClose: prev > 0 ? prev : null,
              change: prev > 0 ? rate - prev : null,
              changePct: prev > 0 ? (rate - prev) / prev : null,
              fetchedAt: DateTime.now(),
            ),
          );
        }
      }
    } catch (_) {
      quotes.addAll(currencies.map((c) => MarketQuote.failure(c, source, '请求失败')));
    }
    return quotes;
  }

  // ---------------------------------------------------------------------------
  // Raw fetch & parse
  // ---------------------------------------------------------------------------

  Future<List<double>?> _fetchOne(String code) async {
    try {
      final text = await _fetchRaw([code]);
      final parsed = _parse(text);
      final q = parsed[code];
      return q;
    } catch (_) {
      return null;
    }
  }

  Future<String> _fetchRaw(List<String> codes) async {
    final resp = await _client.get(
      Uri.parse('$_base${codes.join(',')}'),
      headers: {'Referer': 'https://finance.sina.com.cn'},
    );
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    return latin1.decode(resp.bodyBytes, allowInvalid: true);
  }

  Map<String, List<double>> _parse(String text) {
    final map = <String, List<double>>{};
    final regex = RegExp(r'var hq_str_(\w+)="(.*)";');
    for (final m in regex.allMatches(text)) {
      final code = m.group(1)!;
      final fields = m.group(2)!.split(',');
      if (fields.length < 8) continue;
      map[code] = fields.map((f) => double.tryParse(f.trim()) ?? 0).toList();
    }
    return map;
  }
}
