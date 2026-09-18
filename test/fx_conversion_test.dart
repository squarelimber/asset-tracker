import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/symbols.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_details.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/services/csv_export.dart';
import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';

/// Regression tests for the 2026-09-17 FX-conversion bug: a USD bank-wealth
/// product quoted by its *product* code was treated as rate-linked (unit
/// price = FX rate) just because its market source is `forex`, so its cost
/// (and, in the calendar detail, its market value) silently skipped the FX
/// conversion — the holdings CSV showed 市值 98,210 CNY next to a cost of
/// 14,375 CNY and a profit of +83,835 CNY for a position that is actually
/// down ~1,700 CNY.
///
/// The real 兴业银行 汇利日盈6号A row: 13,083.68 units at 1.098739 USD when
/// USD/CNY was 6.95, latest NAV 1.11833 USD, live USD/CNY 6.7121.
const _usdRate = 6.7121;
const _rates = {'USD': _usdRate};

HoldingRow huiLi() => HoldingRow(
      id: 14,
      accountId: 4,
      name: '汇利日盈6号A',
      assetType: 'bank_wealth',
      marketSource: 'forex',
      symbol: 'Y05A9W10006A',
      quantity: 13083.68,
      costPrice: 1.098739,
      latestPrice: 1.11833,
      costFxRate: 6.95,
      purchaseDate: DateTime(2026, 2, 2),
      currency: 'USD',
      archived: false,
      createdAt: DateTime(2026, 2, 2),
      updatedAt: DateTime(2026, 9, 17),
    );

/// A genuinely rate-linked holding: the code IS the currency and the unit
/// price IS the live rate (市值 = 数量 × 汇率).
HoldingRow fxLinked() => HoldingRow(
      id: 1,
      accountId: 1,
      name: '美元理财',
      assetType: 'bank_wealth',
      marketSource: 'forex',
      symbol: 'USD',
      quantity: 10000,
      costPrice: 7.0,
      latestPrice: 7.1,
      // Explicit: the day-detail service skips holdings whose purchase date
      // (falling back to `createdAt`, which the DB defaults to the wall
      // clock) is after the day being viewed — without it the fixture would
      // silently drop out of the breakdown once the calendar moved on.
      purchaseDate: DateTime(2026, 1, 1),
      currency: 'USD',
      archived: false,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

/// A plain USD holding (e.g. a US stock) — always converts by FX.
HoldingRow usdStock() => HoldingRow(
      id: 2,
      accountId: 1,
      name: '美股',
      assetType: 'stock',
      marketSource: 'sina',
      symbol: 'AAPL',
      quantity: 10,
      costPrice: 200,
      latestPrice: 210,
      currency: 'USD',
      archived: false,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  group('rate-linked detection', () {
    test('only a currency code makes a holding rate-linked', () {
      expect(isFxCurrencyCode('USD'), isTrue);
      expect(isFxCurrencyCode('usd'), isTrue);
      expect(isFxCurrencyCode('EUR'), isTrue);
      expect(isFxCurrencyCode('Y05A9W10006A'), isFalse);
      expect(isFxCurrencyCode('JY040214'), isFalse);
      expect(isFxCurrencyCode(''), isFalse);
      expect(isFxCurrencyCode(null), isFalse);

      expect(isFxLinked(fxLinked()), isTrue);
      // A 银行理财 product code is NOT rate-linked even though the app
      // stores `forex` as its market source.
      expect(isFxLinked(huiLi()), isFalse);
      expect(isFxLinked(usdStock()), isFalse);
    });

    test('conversion rates follow the detection', () {
      // Rate-linked: the conversion is embedded in the unit price.
      expect(valueRateOf(fxLinked(), _rates), 1);
      expect(costRateOf(fxLinked(), _rates), 1);

      // USD NAV product: market at today's rate, cost at the purchase rate.
      expect(valueRateOf(huiLi(), _rates), closeTo(_usdRate, 1e-9));
      expect(costRateOf(huiLi(), _rates), 6.95);

      // USD stock: cost falls back to the current rate without a record.
      expect(valueRateOf(usdStock(), _rates), closeTo(_usdRate, 1e-9));
      expect(costRateOf(usdStock(), _rates), closeTo(_usdRate, 1e-9));
    });
  });

  group('holdings CSV columns share one口径', () {
    List<double> numbersOf(String csv) {
      final row = csv.split('\n')[1].split(',');
      return [
        for (var i = 4; i <= 11; i++)
          if (i != 7 && i != 8) double.parse(row[i]),
      ];
    }

    test('USD NAV product converts market value AND cost', () {
      final csv = const CsvExport().holdings(
        [huiLi()],
        {4: '兴业银行'},
        cnyRates: _rates,
      );
      final row = csv.split('\n')[1].split(',');
      expect(row[7], 'USD');
      final n = numbersOf(csv);
      // 数量, 成本单价, 最新价, 市值(CNY), 成本(CNY), 收益(CNY)
      expect(n[0], closeTo(13083.68, 1e-6));
      expect(n[1], closeTo(1.0987, 1e-4));
      expect(n[2], closeTo(1.1183, 1e-4));
      expect(n[3], closeTo(98210.5871, 1e-3)); // 14631.87 USD × 6.7121
      expect(n[4], closeTo(99910.0689, 1e-3)); // 14375.55 USD × 6.95
      expect(n[5], closeTo(-1699.4818, 1e-3));
      // The two CNY columns can never disagree by a factor of ~7 again.
      expect(n[4] / n[3], closeTo(1.0173, 1e-3));
    });

    test('rate-linked holding is not double-converted', () {
      final csv = const CsvExport().holdings(
        [fxLinked(), usdStock()],
        {1: '某银行'},
        cnyRates: _rates,
      );
      final rows = csv.split('\n');
      // The rate-linked row: the rate already lives in the unit price, so
      // both CNY columns stay 1:1 (no double conversion).
      final linked = rows[1].split(',');
      expect(linked[7], 'USD');
      expect(double.parse(linked[9]), closeTo(71000, 1e-6));
      expect(double.parse(linked[10]), closeTo(70000, 1e-6));
      expect(double.parse(linked[11]), closeTo(1000, 1e-6));
      // A plain USD stock converts both columns by the live rate.
      final stock = rows[2].split(',');
      expect(double.parse(stock[9]), closeTo(14095.41, 1e-3));
      expect(double.parse(stock[10]), closeTo(13424.2, 1e-3));
      expect(double.parse(stock[11]), closeTo(671.21, 1e-3));
    });
  });

  group('calendar day detail and page totals use the same口径', () {
    test('day detail converts a USD NAV product, not a rate-linked one', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final dao = AssetDao(db);
      addTearDown(db.close);
      final accountId =
          await dao.createAccount(AccountsCompanion.insert(name: 'A', type: 'general'));

      Future<int> add(HoldingRow h) => dao.createHolding(HoldingsCompanion.insert(
            accountId: accountId,
            name: h.name,
            assetType: h.assetType,
            marketSource: Value(h.marketSource),
            symbol: Value(h.symbol),
            quantity: Value(h.quantity),
            costPrice: Value(h.costPrice),
            latestPrice: Value(h.latestPrice),
            costFxRate: Value(h.costFxRate),
            purchaseDate: Value(h.purchaseDate),
            currency: Value(h.currency),
          ));

      await add(huiLi());
      await add(fxLinked());

      final service = HoldingDetailService(dao, sources: {});
      final day = DateTime(2026, 9, 17);
      final detail = await service.compute(day, cnyRates: _rates);
      expect(detail, isNotNull);

      final product =
          detail!.items.firstWhere((i) => i.holding.name == '汇利日盈6号A');
      expect(product.cnyRate, closeTo(_usdRate, 1e-9));
      expect(product.marketValueCny, closeTo(98210.5871, 1e-3));
      expect(product.cost, closeTo(99910.0689, 1e-3));

      final linked = detail.items.firstWhere((i) => i.holding.name == '美元理财');
      expect(linked.cnyRate, 1);
      expect(linked.marketValueCny, closeTo(71000, 1e-6));

      expect(detail.totalValue, closeTo(98210.5871 + 71000, 1e-3));
    });

    test('holdings page total matches the portfolio calculator', () {
      final holdings = [huiLi(), fxLinked(), usdStock()];
      final summary = const PortfolioCalculator().compute(holdings, cnyRates: _rates);
      expect(assetTotalOf(holdings, _rates), closeTo(summary.totalAssets, 1e-6));
      // 98,210.5871 + 71,000 + 14,095.41
      expect(summary.totalAssets, closeTo(183305.9971, 1e-3));
    });
  });
}
