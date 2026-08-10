import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import 'market_data_source.dart';

/// Tencent (qt.gtimg.cn) quote source — CORS-friendly (`Access-Control-
/// Allow-Origin: *`) replacement for the Sina endpoints on the web.
///
/// Serves three symbol families in one batch request:
/// - A-shares / HK / US (tilde-separated): `v_SYM="mkt~name~code~price~
///   prevClose~open~...~time~change~changePct~high~low"` — price [3],
///   prevClose [4], change [31], changePct [32].
/// - FX `wh*` (tilde-separated): price [3], prevClose [6], change [12],
///   changePct [13].
/// - Offshore commodities `hf_*` (comma-separated): `v_hf_XAU="price,
///   changePct,?,open,high,low,time,prevClose,..."` — price [0],
///   prevClose [7], changePct [1].
class TencentQuoteSource extends MarketDataSource {
  TencentQuoteSource({http.Client? client, MarketSource source = MarketSource.sina})
      : _client = client ?? http.Client(),
        super(source);

  final http.Client _client;

  static const _base = 'https://qt.gtimg.cn/q=';

  /// Gold aliases accepted for gold holdings.
  static const _goldAliases = {'XAU', 'AU99.99', 'AU9999', 'GOLD'};

  /// Currency codes -> Tencent FX symbols.
  static const _fxSymbols = {
    'USD': 'whUSDCNY',
    'EUR': 'whEURCNY',
    'HKD': 'whHKDCNY',
    'GBP': 'whGBPCNY',
    'AUD': 'whAUDCNY',
    'CAD': 'whCADCNY',
    'JPY': 'whJPYCNY',
    'CHF': 'whCHFCNY',
  };

  @override
  Future<List<MarketQuote>> fetch(List<String> symbols) async {
    final results = <MarketQuote>[];
    for (final batch in MarketFetchHelper.chunk(symbols, 60)) {
      try {
        // Request codes differ from the caller-facing symbols for gold
        // aliases (-> hf_XAU) and currency codes (-> wh*CNY); restore the
        // original symbol on the returned quotes.
        final requestOf = {for (final s in batch) s: _requestCode(s)};
        final resp = await _client.get(
          Uri.parse('$_base${requestOf.values.join(',')}'),
        );
        if (resp.statusCode != 200) {
          results.addAll(
            batch.map((s) => MarketQuote.failure(s, source, 'HTTP ${resp.statusCode}')),
          );
          continue;
        }
        // latin1 maps every raw byte 1:1, preserving all ASCII fields;
        // Chinese names come from the request mapping, never from this text.
        final quotes = _parse(latin1.decode(resp.bodyBytes, allowInvalid: true));
        for (final symbol in batch) {
          final q = quotes[requestOf[symbol]];
          if (q == null) {
            results.add(MarketQuote.failure(symbol, source, '无行情'));
          } else {
            results.add(MarketQuote(
              symbol: symbol,
              source: source,
              name: '',
              price: q.price,
              currency: q.currency,
              prevClose: q.prevClose,
              change: q.change,
              changePct: q.changePct,
              fetchedAt: q.fetchedAt,
            ));
          }
        }
      } catch (_) {
        results.addAll(batch.map((s) => MarketQuote.failure(s, source, '请求失败')));
      }
    }
    return results;
  }

  /// Maps the user-facing symbol to the Tencent request code.
  String _requestCode(String symbol) {
    if (_goldAliases.contains(symbol.toUpperCase())) return 'hf_XAU';
    final fx = _fxSymbols[symbol.toUpperCase()];
    if (fx != null) return fx;
    return symbol;
  }

  Map<String, MarketQuote> _parse(String text) {
    final map = <String, MarketQuote>{};
    final regex = RegExp(r'v_(\w+)="([^"]*)"');
    for (final m in regex.allMatches(text)) {
      final code = m.group(1)!;
      final raw = m.group(2)!;
      final parts = code.startsWith('hf_') ? raw.split(',') : raw.split('~');
      if (code.startsWith('hf_')) {
        _addCommodity(map, code, parts);
      } else if (code.startsWith('wh')) {
        _addFx(map, code, parts);
      } else {
        _addStock(map, code, parts);
      }
    }
    return map;
  }

  /// Stores under the requested symbol; gold aliases and FX codes are
  /// converted back from their Tencent request codes after parsing.
  void _addStock(Map<String, MarketQuote> map, String code, List<String> f) {
    if (f.length < 33) return;
    final price = double.tryParse(f[3]);
    final prev = double.tryParse(f[4]);
    final change = double.tryParse(f[31]);
    final changePct = double.tryParse(f[32]);
    if (price == null || price <= 0) return;
    map[code] = MarketQuote(
      symbol: code,
      source: source,
      name: '',
      price: price,
      currency: 'CNY',
      prevClose: (prev == null || prev <= 0) ? null : prev,
      change: change,
      changePct: changePct == null ? null : changePct / 100,
      fetchedAt: DateTime.now(),
    );
  }

  void _addFx(Map<String, MarketQuote> map, String code, List<String> f) {
    if (f.length < 14) return;
    final price = double.tryParse(f[3]);
    final prev = double.tryParse(f[6]);
    final change = double.tryParse(f[12]);
    final changePct = double.tryParse(f[13]);
    if (price == null || price <= 0) return;
    map[code] = MarketQuote(
      symbol: code,
      source: source,
      name: '',
      price: price,
      currency: 'CNY',
      prevClose: (prev == null || prev <= 0) ? null : prev,
      change: change,
      changePct: changePct == null ? null : changePct / 100,
      fetchedAt: DateTime.now(),
    );
  }

  void _addCommodity(Map<String, MarketQuote> map, String code, List<String> f) {
    if (f.length < 8) return;
    final price = double.tryParse(f[0]);
    final prev = double.tryParse(f[7]);
    final changePct = double.tryParse(f[1]);
    if (price == null || price <= 0) return;
    map[code] = MarketQuote(
      symbol: code,
      source: source,
      name: '',
      price: price,
      currency: 'USD',
      prevClose: (prev == null || prev <= 0) ? null : prev,
      change: (prev == null || prev <= 0) ? null : price - prev,
      changePct: changePct == null ? null : changePct / 100,
      fetchedAt: DateTime.now(),
    );
  }
}

/// Web-only gold/fx adapter: converts gold (USD/oz via hf_XAU) and FX rates
/// (wh*CNY) into the same CNY-per-unit quotes as [GoldFxSource].
class TencentGoldFxAdapter extends MarketDataSource {
  TencentGoldFxAdapter({http.Client? client})
      : _delegate = TencentQuoteSource(
          client: client,
          source: MarketSource.forex,
        ),
        super(MarketSource.forex);

  final TencentQuoteSource _delegate;

  static const _goldAliases = {'XAU', 'AU99.99', 'AU9999', 'GOLD'};
  static const _fxSymbols = {
    'USD': 'whUSDCNY',
    'EUR': 'whEURCNY',
    'HKD': 'whHKDCNY',
    'GBP': 'whGBPCNY',
    'AUD': 'whAUDCNY',
    'CAD': 'whCADCNY',
    'JPY': 'whJPYCNY',
    'CHF': 'whCHFCNY',
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
    final goldQuotes = await _delegate.fetch(
      golds.isEmpty ? const [] : const ['XAU', 'USD'],
    );
    final fxQuotes = await _delegate.fetch(fx);

    // The USD rate is fetched together with gold (first request) even when
    // no FX symbols were requested, so search both batches for it.
    final fxBySymbol = {
      for (final q in [...goldQuotes, ...fxQuotes]) q.symbol: q,
    };
    final usdRate = fxBySymbol['USD'];
    final xau = golds.isEmpty
        ? null
        : goldQuotes.cast<MarketQuote?>().firstWhere(
            (q) => q != null &&
                q.isSuccess &&
                _goldAliases.contains(q.symbol.toUpperCase()),
            orElse: () => null,
          );

    for (final g in golds) {
      if (usdRate == null || !usdRate.isSuccess) {
        results.add(MarketQuote.failure(g, source, '汇率不可用'));
        continue;
      }
      if (xau == null) {
        results.add(MarketQuote.failure(g, source, '金价不可用'));
        continue;
      }
      final usdPerOz = xau.price;
      if (usdPerOz <= 0) {
        results.add(MarketQuote.failure(g, source, '金价异常'));
        continue;
      }
      final cnyPerGram = usdPerOz * usdRate.price / _ozToGram;
      final prevUsd = xau.prevClose;
      final prevCny = (prevUsd == null || prevUsd <= 0)
          ? null
          : prevUsd * usdRate.price / _ozToGram;
      results.add(MarketQuote(
        symbol: g.toUpperCase(),
        source: source,
        name: '黄金 (Au99.99)',
        price: cnyPerGram,
        currency: 'CNY',
        prevClose: prevCny,
        change: prevCny == null ? null : cnyPerGram - prevCny,
        changePct: prevCny == null || prevCny == 0
            ? null
            : (cnyPerGram - prevCny) / prevCny,
        fetchedAt: DateTime.now(),
      ));
    }

    for (final c in fx) {
      final q = fxBySymbol[_fxSymbols[c]];
      if (q == null || !q.isSuccess) {
        results.add(MarketQuote.failure(c, source, '无行情'));
      } else {
        results.add(MarketQuote(
          symbol: c,
          source: source,
          name: 'CNY/$c',
          price: q.price,
          currency: 'CNY',
          prevClose: q.prevClose,
          change: q.change,
          changePct: q.changePct,
          fetchedAt: DateTime.now(),
        ));
      }
    }

    final covered = {...golds.map((g) => g.toUpperCase()), ...fx};
    for (final s in symbols) {
      if (!covered.contains(s.toUpperCase())) {
        results.add(MarketQuote.failure(s, source, '不支持的代码'));
      }
    }
    return results;
  }
}
