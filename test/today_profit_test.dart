import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/symbols.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/features/holdings/holdings_page.dart';

HoldingRow _holding({
  String? symbol,
  String assetType = 'stock',
  String marketSource = 'sina',
  double quantity = 100,
}) {
  return HoldingRow(
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
    currency: 'CNY',
    riskLevel: null,
    note: null,
  );
}

PriceCacheRow _cache({
  double? change,
  double? changePct,
  DateTime? fetchedAt,
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

  group('todayChangePctOf', () {
    test('returns the fraction change for today', () {
      expect(todayChangePctOf(_cache(changePct: 0.0123)), closeTo(0.0123, 1e-9));
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
}
