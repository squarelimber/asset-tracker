import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/symbols.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';

HoldingRow _holding({
  String? symbol,
  String assetType = 'stock',
  String marketSource = 'sina',
  double quantity = 100,
  String currency = 'CNY',
}) {
  return HoldingRow(
    costRecorded: false,
    id: 1,
    accountId: 1,
    name: '测试',
    assetType: assetType,
    marketSource: marketSource,
    symbol: symbol,
    quantity: quantity,
    costPrice: 1,
    latestPrice: 1,
    purchaseDate: DateTime(2026, 1, 1),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    currency: currency,
    riskLevel: null,
    note: null,
    archived: false,
  );
}

PriceCacheRow _cache({
  double? change, double? changePct, DateTime? fetchedAt, String? quoteDate,
}) {
  return PriceCacheRow(
    symbol: 'sh600519',
    source: 'sina',
    name: '',
    price: 100,
    currency: 'CNY',
    prevClose: change == null ? null : 100 - change,
    change: change,
    changePct: changePct,
    fetchedAt: fetchedAt ?? DateTime.now(),
    quoteDate: quoteDate,
  );
}

void main() {
  group('cacheSymbolFor', () {
    test('normalizes bare 6-digit Sina codes', () {
      expect(cacheSymbolFor(_holding(symbol: '600519')), 'sh600519');
      expect(cacheSymbolFor(_holding(symbol: '159915')), 'sz159915');
    });

    test('passes through prefixed codes', () {
      expect(cacheSymbolFor(_holding(symbol: 'sh600519')), 'sh600519');
    });

    test('gold without a symbol defaults to AU99.99', () {
      expect(
        cacheSymbolFor(_holding(assetType: 'gold', marketSource: 'sge')),
        'AU99.99',
      );
    });

    test('amount-based assets have no cache symbol', () {
      expect(cacheSymbolFor(_holding(assetType: 'savings')), isNull);
    });
  });

  group('todayProfitOf', () {
    test('a NAV fetched today cannot re-label the previous session', () {
      final now = DateTime.utc(2026, 11, 17, 7);
      final stale = _cache(
        change: 1.5, changePct: 0.015, fetchedAt: now, quoteDate: '2026-11-16',
      );
      final current = _cache(
        change: 1.5, changePct: 0.015, fetchedAt: now, quoteDate: '2026-11-17',
      );
      expect(todayProfitOf(stale, 200, now: now, source: MarketSource.eastmoney), isNull);
      expect(todayChangePctOf(stale, now: now, source: MarketSource.eastmoney), isNull);
      expect(todayProfitOf(current, 200, now: now, source: MarketSource.eastmoney), 300);
      expect(todayChangePctOf(current, now: now, source: MarketSource.eastmoney), 0.015);
    });
    test('change x quantity for a quote written today', () {
      final row = _cache(change: 1.5);
      expect(todayProfitOf(row, 200), 300.0);
    });

    test('null when the quote has no change', () {
      expect(todayProfitOf(_cache(change: null), 200), isNull);
      expect(todayProfitOf(null, 200), isNull);
    });

    test('null when the cache is not from today', () {
      final row = _cache(
        change: 1.5,
        fetchedAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(todayProfitOf(row, 200), isNull);
    });
  });

  group('todayProfitOf intraday trades', () {
    final now = DateTime(2026, 9, 14, 15);
    final row = _cache(change: 10, fetchedAt: now);
    TransactionRow trade(
      String type,
      double? qty,
      double? price, {
      int holdingId = 1,
      DateTime? occurredAt,
    }) => TransactionRow(
      id: 1,
      accountId: 1,
      holdingId: holdingId,
      type: type,
      quantity: qty,
      price: price,
      amount: (qty ?? 0) * (price ?? 0),
      currency: 'CNY',
      occurredAt: occurredAt ?? DateTime(2026, 9, 14, 14),
      costMoved: false,
      internalMove: false,
      updatedAt: now,
    );
    double? calculate(double quantity, List<TransactionRow> trades) =>
        todayProfitOf(
          row,
          quantity,
          now: now,
          transactions: trades,
          holdingId: 1,
        );

    test('no trade retains the day change for opening shares', () {
      expect(calculate(100, []), 1000);
    });
    test(
      'new position measures from actual buy price, not yesterday close',
      () {
        expect(calculate(46, [trade('buy', 46, 101)]), -46);
      },
    );
    test('existing position and newly bought shares use their own bases', () {
      expect(calculate(150, [trade('buy', 50, 98)]), 1100);
    });
    test('sold shares use the actual sale price rather than last price', () {
      expect(calculate(60, [trade('sell', 40, 95)]), 800);
    });
    test('intraday round trip uses buy and sell execution prices', () {
      expect(
        calculate(0, [
          trade('buy', 10, 92, occurredAt: DateTime(2026, 9, 14, 10)),
          trade('sell', 10, 95, occurredAt: DateTime(2026, 9, 14, 11)),
        ]),
        30,
      );
    });
    test('unrelated holding and previous day trades do not affect result', () {
      expect(
        calculate(100, [
          trade('buy', 50, 99, holdingId: 2),
          trade('buy', 50, 99, occurredAt: DateTime(2026, 9, 13, 14)),
        ]),
        1000,
      );
    });
    test(
      'missing trade data, share splits and impossible shares are unavailable',
      () {
        expect(calculate(100, [trade('buy', null, 99)]), isNull);
        expect(calculate(100, [trade('buy', 10, null)]), isNull);
        expect(calculate(100, [trade('split', null, null)]), isNull);
        expect(calculate(10, [trade('buy', 100, 99)]), isNull);
        expect(
          calculate(100, [
            trade(
              'buy',
              10,
              99,
              occurredAt: now.add(const Duration(minutes: 1)),
            ),
          ]),
          isNull,
        );
      },
    );
  });

  group('todayChangePctOf', () {
    test('returns the fraction change for today', () {
      expect(
        todayChangePctOf(_cache(changePct: 0.0123)),
        closeTo(0.0123, 1e-9),
      );
    });

    test('null for stale or missing data', () {
      expect(todayChangePctOf(_cache(changePct: null)), isNull);
      expect(todayChangePctOf(null), isNull);
      final stale = _cache(
        changePct: 0.01,
        fetchedAt: DateTime.now().subtract(const Duration(days: 2)),
      );
      expect(todayChangePctOf(stale), isNull);
    });
  });

  group('quote change attribution', () {
    // 2026-09-12 = Saturday, 09-13 = Sunday, 09-14 = Monday.
    test('a weekend quote still describes Friday, not today', () {
      final saturday = DateTime(2026, 9, 12, 10);
      final row = _cache(change: 1.5, changePct: 0.015, fetchedAt: saturday);

      // The exchange keeps serving Friday's close pair all weekend; showing
      // it as Saturday's move double-counts Friday's session.
      expect(
        todayProfitOf(row, 200, now: saturday, source: MarketSource.sina),
        isNull,
      );
      expect(
        todayChangePctOf(row, now: saturday, source: MarketSource.sina),
        isNull,
      );
      // Gold and FX stop over the weekend too.
      expect(
        todayProfitOf(row, 200, now: saturday, source: MarketSource.sge),
        isNull,
      );
      // Crypto keeps trading, so its change is genuinely Saturday's.
      expect(
        todayProfitOf(row, 200, now: saturday, source: MarketSource.coingecko),
        300.0,
      );
    });

    test('a weekday quote fetched before the open is not today\'s either', () {
      final preOpen = DateTime(2026, 9, 14, 8);
      final row = _cache(change: 1.5, fetchedAt: preOpen);
      expect(
        todayProfitOf(row, 200, now: preOpen, source: MarketSource.sina),
        isNull,
      );

      final open = DateTime(2026, 9, 14, 14);
      final fresh = _cache(change: 1.5, fetchedAt: open);
      expect(
        todayProfitOf(fresh, 200, now: open, source: MarketSource.sina),
        300.0,
      );
    });

    test('the session gate is opt-in for callers without a source', () {
      final saturday = DateTime(2026, 9, 12, 10);
      final row = _cache(change: 1.5, fetchedAt: saturday);
      expect(todayProfitOf(row, 200, now: saturday), 300.0);
    });
  });

  group('assetTotalOf / liabilityTotalOf', () {
    HoldingRow amountHolding(String type, double qty, [double rate = 1]) =>
        _holding(assetType: type, marketSource: 'manual', quantity: qty);

    test('assets only: liabilities are excluded from the asset total', () {
      final list = [
        amountHolding('savings', 1000), // 现金 1000
        _holding(
          symbol: 'sh600519',
          quantity: 100,
        ), // 茅台 100 * latestPrice(1) = 100
        amountHolding('liability', 3000), // 负债 3000 -> excluded
      ];
      const rates = <String, double>{};
      expect(assetTotalOf(list, rates), 1100);
      expect(liabilityTotalOf(list, rates), 3000);
    });

    test('applies currency conversion rates', () {
      final usd = _holding(quantity: 2, currency: 'USD');
      const rates = <String, double>{'USD': 7.2};
      expect(assetTotalOf([usd], rates), closeTo(2 * 1 * 7.2, 1e-9));
    });
  });
}
