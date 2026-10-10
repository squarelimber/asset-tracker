import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/services/market/price_sanity.dart';

void main() {
  group('isPlausiblePriceRefresh', () {
    test('rejects the 东方添益债券 / 蓝璟5 code collision', () {
      // 400030 exists in two markets: the fund (NAV 1.4553) and the
      // third-board stock 蓝璟5 (0.063). A 23x move between two refreshes is
      // not a market move — no listed CNY instrument covers that distance.
      expect(
        isPlausiblePriceRefresh(
          source: MarketSource.eastmoney,
          previousPrice: 1.4553,
          newPrice: 0.063,
        ),
        isFalse,
      );
      // …and the collision must be caught in both directions (a cheap code
      // answered by a pricier instrument).
      expect(
        isPlausiblePriceRefresh(
          source: MarketSource.eastmoney,
          previousPrice: 0.063,
          newPrice: 1.4553,
        ),
        isFalse,
      );
    });

    test('the band is deliberately loose enough for real market moves', () {
      // A 5x gap is inside the range a 北交所 stock or a fresh listing can
      // legitimately cover, so it is *not* rejected here — that kind of
      // collision is prevented structurally instead, by never asking a
      // stock endpoint about a fund (see eastmoney_fund_quote_source.dart).
      expect(
        isPlausiblePriceRefresh(
          source: MarketSource.eastmoney,
          previousPrice: 4.6809,
          newPrice: 26.25,
        ),
        isTrue,
      );
    });

    test('accepts ordinary daily moves', () {
      expect(
        isPlausiblePriceRefresh(
          source: MarketSource.eastmoney,
          previousPrice: 1.4553,
          newPrice: 1.5,
        ),
        isTrue,
      );
      expect(
        isPlausiblePriceRefresh(
          source: MarketSource.sina,
          previousPrice: 1348.86,
          newPrice: 1200,
        ),
        isTrue,
      );
    });

    test('accepts anything when there is no previous price', () {
      expect(
        isPlausiblePriceRefresh(
          source: MarketSource.eastmoney,
          previousPrice: 0,
          newPrice: 0.063,
        ),
        isTrue,
      );
    });

    test('rejects non-positive prices', () {
      expect(
        isPlausiblePriceRefresh(
          source: MarketSource.sina,
          previousPrice: 10,
          newPrice: 0,
        ),
        isFalse,
      );
    });

    test('exempts crypto, which can legitimately multiply', () {
      expect(
        isPlausiblePriceRefresh(
          source: MarketSource.coingecko,
          previousPrice: 1,
          newPrice: 25,
        ),
        isTrue,
      );
    });
  });
}
