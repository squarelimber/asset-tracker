// Live network verification of market data endpoints.
// Skipped by default; run with:
//   flutter test --dart-define=LIVE=true test/live_market_sources_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/services/market/eastmoney_source.dart';
import 'package:asset_tracker/services/market/gold_fx_source.dart';
import 'package:asset_tracker/services/market/sina_source.dart';

const live = bool.fromEnvironment('LIVE');

void main() {
  test(
    'live: sina A-share quotes',
    () async {
      final source = SinaSource();
      final quotes = await source.fetch(['sh600519', 'sz159915']);
      for (final q in quotes) {
        // ignore: avoid_print
        print('${q.symbol}: ok=${q.isSuccess} price=${q.price}');
      }
      expect(quotes.any((q) => q.isSuccess), isTrue);
    },
    skip: !live,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'live: eastmoney fund NAV',
    () async {
      final source = EastmoneySource();
      final quotes = await source.fetch(['110022', '005827']);
      for (final q in quotes) {
        // ignore: avoid_print
        print('${q.symbol}: ok=${q.isSuccess} name=${q.name} price=${q.price}');
      }
      expect(quotes.any((q) => q.isSuccess), isTrue);
    },
    skip: !live,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'live: gold and FX',
    () async {
      final source = GoldFxSource();
      final quotes = await source.fetch(['AU99.99', 'USD', 'EUR', 'HKD', 'JPY']);
      for (final q in quotes) {
        // ignore: avoid_print
        print('${q.symbol}: ok=${q.isSuccess} price=${q.price.toStringAsFixed(4)}');
      }
      expect(quotes.any((q) => q.isSuccess), isTrue);
    },
    skip: !live,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
