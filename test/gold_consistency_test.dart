// Regression guard for the "gold is two different instruments" bug: the live
// gold quote (London spot, USD/oz -> CNY/gram) and the backfilled gold price
// series must price the SAME thing. When they did not, their basis landed on
// the one day written by the live path (today) and showed up as a large fake
// daily return that disappeared on the next rebuild.
//
// Both sources are driven through the real code paths here (only the HTTP
// layer is mocked) so the assertion covers parsing, the conversion and the
// date handling, not just the shared constant.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:asset_tracker/core/gold.dart';
import 'package:asset_tracker/services/market/gold_fx_source.dart';
import 'package:asset_tracker/services/market/history_source.dart';

/// hf_XAU row: [current, prevClose, ...] (USD per troy ounce).
const _xauSpot = 'var hq_str_hf_XAU="4316.88,4348.35,0,4330.02,4355.29,4315.54,'
    '23:59:59,4348.35,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0";';

/// fx_susdcny row: the adapter reads the live rate from index 3.
const _usdCnySpot = 'var hq_str_fx_susdcny="2026-09-14,6.7112,6.7039,6.7096,'
    '6.7112,6.7039,6.7112,6.7090,2026-09-14";';

/// Daily London gold closes (USD/oz).
const _xauHistory = '/*<script>*/var _=(['
    '{"date":"2026-09-11","open":"4316.950","high":"4402.190","low":"4292.650","close":"4348.350","volume":"0"},'
    '{"date":"2026-09-14","open":"4330.020","high":"4355.290","low":"4315.540","close":"4316.880","volume":"0"}'
    ']);';

/// Daily USD/CNY closes: `date,open,high,low,close,|...`
/// Note 2026-09-12/13 (weekend) are absent — gold and FX calendars differ.
const _usdCnyHistory = '(2026-09-11,6.7080,6.6959,6.7158,6.7114,|'
    '2026-09-14,6.7112,6.7039,6.7112,6.7096,)';

http.Response _resp(String body) => http.Response.bytes(
      body.codeUnits,
      200,
      headers: {'content-type': 'text/plain; charset=utf-8'},
    );

/// Serves the live and historical gold/FX endpoints.
MockClient _client() => MockClient((request) async {
      final url = request.url.toString();
      if (url.contains('GlobalFuturesService')) return _resp(_xauHistory);
      if (url.contains('NewForexService')) return _resp(_usdCnyHistory);
      if (url.contains('hq.sinajs.cn')) {
        return _resp(url.contains('hf_XAU') ? _xauSpot : _usdCnySpot);
      }
      return http.Response('not found', 404);
    });

void main() {
  group('gold live vs history instrument', () {
    test('live quote uses the shared ounce->gram conversion', () async {
      final quote = (await GoldFxSource(client: _client()).fetch(['XAU'])).single;

      expect(quote.isSuccess, isTrue);
      expect(quote.currency, 'CNY');
      expect(quote.name, goldQuoteName);
      expect(quote.price, closeTo(goldCnyPerGram(4316.88, 6.7096), 1e-9));
    });

    test('history for the same day produces the same CNY/gram price', () async {
      final quote = (await GoldFxSource(client: _client()).fetch(['XAU'])).single;
      final history = await XauGoldHistorySource(client: _client())
          .fetch('AU99.99', DateTime(2026, 9, 1), DateTime(2026, 9, 14));

      expect(history.keys, contains('2026-09-14'));
      // Same instrument + same formula + same inputs => identical value. Any
      // second instrument (e.g. the Shanghai futures contract) reappearing in
      // either path breaks this assertion, which is the whole point.
      expect(history['2026-09-14'], closeTo(quote.price, 1e-9));
    });

    test('each gold day is paired with the latest FX rate on or before it',
        () async {
      final history = await XauGoldHistorySource(client: _client())
          .fetch('AU99.99', DateTime(2026, 9, 1), DateTime(2026, 9, 14));

      expect(history['2026-09-11'], closeTo(goldCnyPerGram(4348.35, 6.7114), 1e-9));
      expect(history['2026-09-14'], closeTo(goldCnyPerGram(4316.88, 6.7096), 1e-9));
    });

    test('the requested window is honoured', () async {
      final history = await XauGoldHistorySource(client: _client())
          .fetch('AU99.99', DateTime(2026, 9, 14), DateTime(2026, 9, 14));

      expect(history.keys, ['2026-09-14']);
    });

    test('an unavailable FX series yields no gold history instead of raw USD',
        () async {
      final client = MockClient((request) async {
        if (request.url.toString().contains('GlobalFuturesService')) {
          return _resp(_xauHistory);
        }
        return http.Response('boom', 500);
      });

      final history = await XauGoldHistorySource(client: client)
          .fetch('AU99.99', DateTime(2026, 9, 1), DateTime(2026, 9, 14));

      // Without the FX leg the series cannot be converted into CNY; returning
      // USD/oz numbers would silently mis-price the holding by ~7x.
      expect(history, isEmpty);
    });
  });
}
