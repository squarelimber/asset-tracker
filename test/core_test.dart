import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';

void main() {
  test('AssetType storage round-trip', () {
    for (final t in AssetType.values) {
      expect(AssetType.fromStorage(t.storageName), t);
    }
    expect(AssetType.fromStorage('unknown'), AssetType.cash);
  });

  test('AssetType market-linked classification', () {
    expect(AssetType.stock.isMarketLinked, isTrue);
    expect(AssetType.etf.isMarketLinked, isTrue);
    expect(AssetType.mutualFund.isMarketLinked, isTrue);
    expect(AssetType.gold.isMarketLinked, isTrue);
    expect(AssetType.crypto.isMarketLinked, isTrue);
    expect(AssetType.bankWealth.isMarketLinked, isFalse);
    expect(AssetType.cash.isMarketLinked, isFalse);
  });

  test('MarketSource storage round-trip', () {
    for (final s in MarketSource.values) {
      expect(MarketSource.fromStorage(s.storageName), s);
    }
  });

  test('Formats.amount', () {
    expect(Formats.amount(1234.5), '1,234.50');
    expect(Formats.amount(0), '0.00');
  });

  test('Formats.signedAmount', () {
    expect(Formats.signedAmount(10), '+10.00');
    expect(Formats.signedAmount(-5.5), '-5.50');
  });

  test('Formats.pct', () {
    expect(Formats.pct(0.1234), '12.34%');
  });

  test('Formats.money respects currency', () {
    expect(Formats.money(1234.5), '¥1,234.50');
    expect(Formats.money(1234.5, 'USD'), '\$1,234.50');
    expect(Formats.money(1234.5, 'EUR'), '€1,234.50');
    expect(Formats.money(1234.5, 'HKD'), 'HK\$1,234.50');
    expect(Formats.money(1234.5, 'XXX'), 'XXX 1,234.50');
    expect(Formats.money(0), '¥0.00');
  });
}
