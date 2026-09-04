import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/services/market/fallback_source.dart';
import 'package:asset_tracker/services/market/market_data_source.dart';
import 'package:asset_tracker/services/market/sina_source.dart';
import 'package:asset_tracker/services/market/tencent_quote_source.dart';

/// Stub source returning preconfigured prices (0 / missing = failure).
class _StubSource extends MarketDataSource {
  _StubSource(MarketSource source, this.prices) : super(source);

  final Map<String, double> prices;
  int fetchCount = 0;

  @override
  Future<List<MarketQuote>> fetch(List<String> symbols) async {
    fetchCount++;
    return symbols.map((s) {
      final price = prices[s] ?? 0;
      if (price <= 0) return MarketQuote.failure(s, source, 'stub failure');
      return MarketQuote(
        symbol: s,
        source: source,
        name: '',
        price: price,
        fetchedAt: DateTime.now(),
      );
    }).toList();
  }
}

void main() {
  group('FallbackSource', () {
    test('reports the primary source label', () {
      final source = FallbackSource(
        _StubSource(MarketSource.sina, {}),
        _StubSource(MarketSource.sina, {}),
      );
      expect(source.source, MarketSource.sina);
    });

    test('returns primary quotes untouched when all succeed', () async {
      final secondary = _StubSource(MarketSource.sina, {'sh600519': 999});
      final source = FallbackSource(
        _StubSource(MarketSource.sina, {'sh600519': 100}),
        secondary,
      );
      final quotes = await source.fetch(['sh600519']);
      expect(quotes.single.price, 100);
      expect(secondary.fetchCount, 0, reason: 'secondary must not be called');
    });

    test('retries only failed symbols against the secondary', () async {
      final secondary = _StubSource(MarketSource.sina, {'sz000001': 10});
      final source = FallbackSource(
        _StubSource(MarketSource.sina, {'sh600519': 100, 'sz000001': 0}),
        secondary,
      );
      final quotes = await source.fetch(['sh600519', 'sz000001']);
      expect(quotes, hasLength(2));
      expect(quotes[0].price, 100);
      expect(quotes[1].price, 10);
      expect(secondary.fetchCount, 1);
    });

    test('keeps the failure when the secondary also fails', () async {
      final source = FallbackSource(
        _StubSource(MarketSource.sina, {'sh600519': 0}),
        _StubSource(MarketSource.sina, {'sh600519': 0}),
      );
      final quotes = await source.fetch(['sh600519']);
      expect(quotes.single.isSuccess, isFalse);
    });

    test('matches secondary symbols case-insensitively', () async {
      // GoldFxSource uppercases gold symbols; the stub mimics that on the
      // primary side while the secondary echoes the original case.
      final secondary = _StubSource(MarketSource.forex, {'xau': 700});
      final source = FallbackSource(
        _StubSource(MarketSource.forex, {'XAU': 0}),
        secondary,
      );
      final quotes = await source.fetch(['XAU']);
      expect(quotes.single.isSuccess, isTrue);
      expect(quotes.single.symbol, 'XAU',
          reason: 're-emitted under the requested symbol');
      expect(quotes.single.price, 700);
    });

    test('sina failure falls back to tencent (real sources)', () async {
      // Primary (Sina) returns an empty quote; secondary (Tencent) serves it.
      final sinaClient = MockClient((req) async => http.Response.bytes(
            'var hq_str_sh600519="";'.codeUnits,
            200,
          ));
      final tencentClient = MockClient((req) async {
        final fields = List.filled(35, '0');
        fields[3] = '1348.86';
        fields[4] = '1309.22';
        fields[31] = '39.64';
        fields[32] = '3.03';
        return http.Response.bytes(
          'v_sh600519="${fields.join('~')}";'.codeUnits,
          200,
        );
      });
      final source = FallbackSource(
        SinaSource(client: sinaClient),
        TencentQuoteSource(client: tencentClient, source: MarketSource.sina),
      );
      final quotes = await source.fetch(['sh600519']);
      expect(quotes.single.isSuccess, isTrue);
      expect(quotes.single.symbol, 'sh600519');
      expect(quotes.single.price, 1348.86);
      expect(quotes.single.source, MarketSource.sina);
    });
  });
}
