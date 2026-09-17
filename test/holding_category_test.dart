import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_category.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/domain/rule_engine.dart';
import 'package:asset_tracker/services/backup_service.dart';
import 'package:asset_tracker/sync/sync_format.dart';
import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';

/// Regression: a holding's *product* type and its *allocation category* are
/// independent.
///
/// Before the `categoryOverride` column existed they were one and the same
/// (`AssetType.category`), so any fund tracking something other than
/// equities was misfiled: a 豆粕ETF / 黄金ETF is an 场内基金 (share-based,
/// Sina-priced) but its exposure is 商品 / 黄金. The old model also forced the
/// two apart in a damaging way — picking the 商品 category disabled the
/// symbol field, so the product code could not even be recorded.
HoldingRow _holding({
  required int id,
  required String assetType,
  String? categoryOverride,
  String? symbol,
  String marketSource = 'manual',
  double quantity = 1,
  double cost = 90,
  double price = 100,
  String currency = 'CNY',
}) {
  return HoldingRow(
    id: id,
    accountId: 1,
    name: 'h$id',
    assetType: assetType,
    marketSource: marketSource,
    categoryOverride: categoryOverride,
    symbol: symbol,
    quantity: quantity,
    costPrice: cost,
    latestPrice: price,
    currency: currency,
    archived: false,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

AlertRuleRow _rule(AlertRuleType type, Map<String, dynamic> params) =>
    AlertRuleRow(
      id: 1,
      type: type.storageName,
      name: type.label,
      params: jsonEncode(params),
      enabled: true,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

RuleContext _ctx(List<HoldingRow> holdings) => RuleContext(
      summary: const PortfolioCalculator().compute(holdings),
      holdings: holdings,
      cnyRates: const {},
      now: DateTime(2026, 8, 8),
    );

void main() {
  group('effectiveCategoryOf', () {
    test('falls back to the asset type when there is no override', () {
      expect(
        effectiveCategoryOf(_holding(id: 1, assetType: 'etf')),
        AssetCategory.equity,
      );
    });

    test('an override wins over the type (商品ETF filed under 商品)', () {
      final etf = _holding(
        id: 1,
        assetType: 'etf',
        categoryOverride: 'commodity',
      );
      expect(effectiveCategoryOf(etf), AssetCategory.commodity);
      // The product type is untouched — it is still an 场内基金.
      expect(AssetType.fromStorage(etf.assetType), AssetType.etf);
    });

    test('an unreadable override (newer app version) falls back cleanly', () {
      expect(
        effectiveCategoryOf(
          _holding(id: 1, assetType: 'etf', categoryOverride: 'crypto_etf_v9'),
        ),
        AssetCategory.equity,
      );
      expect(
        hasCategoryOverride(
          _holding(id: 1, assetType: 'etf', categoryOverride: 'crypto_etf_v9'),
        ),
        isFalse,
      );
    });

    test('a liability never takes an override', () {
      // Liabilities are deducted from net worth, never allocated, and the
      // dialogs refuse to store one — a foreign value must not leak in.
      expect(
        effectiveCategoryOf(
          _holding(id: 1, assetType: 'liability', categoryOverride: 'equity'),
        ),
        AssetCategory.cash,
      );
    });
  });

  group('PortfolioSummary.categoryBreakdown', () {
    test('groups by effective category, not by asset type', () {
      final holdings = [
        _holding(id: 1, assetType: 'stock', quantity: 1, price: 1000),
        // 豆粕ETF: an 场内基金 whose exposure is 商品.
        _holding(
          id: 2,
          assetType: 'etf',
          categoryOverride: 'commodity',
          quantity: 1,
          price: 200,
        ),
        // 沪深300ETF: an 场内基金 whose exposure really is 权益.
        _holding(id: 3, assetType: 'etf', quantity: 1, price: 300),
      ];
      final s = const PortfolioCalculator().compute(holdings);

      final byCat = {for (final c in s.categoryBreakdown) c.category: c.marketValue};
      expect(byCat[AssetCategory.commodity], 200);
      expect(byCat[AssetCategory.equity], 1300);
      // Summing the category view must still equal the portfolio total.
      expect(
        s.categoryBreakdown.fold<double>(0, (a, c) => a + c.marketValue),
        closeTo(s.totalAssets, 1e-9),
      );

      // The by-type view keeps both funds together — that is intentional,
      // the two views answer different questions.
      final byType = {for (final t in s.breakdown) t.type: t.marketValue};
      expect(byType[AssetType.etf], 500);
    });

    test('a liability stays out of the category breakdown', () {
      final holdings = [
        _holding(id: 1, assetType: 'cash', quantity: 1000, price: 1),
        _holding(id: 2, assetType: 'liability', quantity: 400, price: 1),
      ];
      final s = const PortfolioCalculator().compute(holdings);
      expect(s.totalLiabilities, 400);
      expect(s.categoryBreakdown.single.category, AssetCategory.cash);
      expect(s.categoryBreakdown.single.marketValue, 1000);
    });
  });

  group('配置比例偏离 uses the effective category', () {
    // target 0.5, tolerance 0.1 -> the acceptable equity band is 40%..60%.
    final params = {'target': 0.5, 'tolerance': 0.1};

    test('a misclassified 商品ETF inflates the equity ratio', () {
      final holdings = [
        _holding(id: 1, assetType: 'stock', quantity: 1, price: 400),
        // 300 of 商品 exposure recorded as a plain 场内基金.
        _holding(id: 2, assetType: 'etf', quantity: 1, price: 300),
        _holding(id: 3, assetType: 'cash', quantity: 300, price: 1),
      ];
      final results = const AssetRatioEvaluator()
          .evaluate(_rule(AlertRuleType.assetRatio, params), _ctx(holdings));
      expect(results, hasLength(1));
      expect(results.single.message, contains('偏高'));
    });

    test('marking it 商品 takes the equity ratio back into range', () {
      final holdings = [
        _holding(id: 1, assetType: 'stock', quantity: 1, price: 400),
        _holding(
          id: 2,
          assetType: 'etf',
          categoryOverride: 'commodity',
          quantity: 1,
          price: 300,
        ),
        _holding(id: 3, assetType: 'cash', quantity: 300, price: 1),
      ];
      final results = const AssetRatioEvaluator()
          .evaluate(_rule(AlertRuleType.assetRatio, params), _ctx(holdings));
      expect(results, isEmpty);
    });
  });

  group('persistence', () {
    test('sync payload carries the override', () {
      final row = const SyncFormatter().holdingToRow(
        _holding(id: 1, assetType: 'etf', categoryOverride: 'commodity'),
      );
      expect(row['categoryOverride'], 'commodity');
      expect(const SyncFormatter().holdingToRow(
        _holding(id: 1, assetType: 'etf'),
      )['categoryOverride'], isNull);
    });
  });

  group('backup', () {
    late AppDatabase db;
    late AssetDao dao;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      dao = AssetDao(db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> seed() async {
      await dao.createAccount(
        AccountsCompanion.insert(name: '券商', type: 'general'),
      );
      await dao.createHolding(HoldingsCompanion.insert(
        accountId: 1,
        name: '豆粕ETF',
        assetType: 'etf',
        marketSource: const Value('sina'),
        symbol: const Value('sz159985'),
        quantity: const Value(10000),
        costPrice: const Value(1.0),
        latestPrice: const Value(1.1),
        categoryOverride: const Value('commodity'),
      ));
    }

    test('round-trip keeps the override', () async {
      await seed();
      final json = await BackupService(dao).exportJson();

      final restored = AppDatabase(NativeDatabase.memory());
      final restoredDao = AssetDao(restored);
      await BackupService(restoredDao).importJson(json);
      final h = (await restoredDao.getHoldings()).single;
      expect(h.assetType, 'etf');
      expect(h.categoryOverride, 'commodity');
      await restored.close();
    });

    test('a backup written before the column exists imports as no override',
        () async {
      await seed();
      final json = await BackupService(dao).exportJson();
      // Simulate an older backup: the key is simply absent.
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      for (final h in decoded['holdings'] as List) {
        (h as Map<String, dynamic>).remove('categoryOverride');
      }

      final restored = AppDatabase(NativeDatabase.memory());
      final restoredDao = AssetDao(restored);
      await BackupService(restoredDao).importJson(jsonEncode(decoded));
      final h = (await restoredDao.getHoldings()).single;
      expect(h.categoryOverride, isNull);
      // No override means "follow the asset type", which is the old
      // behaviour — an old backup must not change any allocation figure.
      expect(effectiveCategoryOf(h), AssetCategory.equity);
      await restored.close();
    });
  });

  group('add-holding dialog', () {
    testWidgets('a 商品ETF can be recorded with a code and 商品 category',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = AppDatabase(NativeDatabase.memory());
      final dao = AssetDao(db);
      await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'),
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: HoldingsPage()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('添加持仓'));
      await tester.pumpAndSettle();

      // Pick the 商品 exposure first...
      await tester.tap(find.widgetWithText(ChoiceChip, '商品'));
      await tester.pumpAndSettle();

      // ...then the fund *product* type. Before the fix 基金 was not offered
      // under 商品 at all, and 期货 (the only share-based entry) had its
      // symbol field disabled.
      await tester.tap(find.byType(DropdownButtonFormField<AssetType>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('基金').last);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), '豆粕ETF');
      await tester.enterText(find.byType(TextField).at(1), '159985');
      await tester.enterText(find.byType(TextField).at(2), '10000');
      await tester.enterText(find.byType(TextField).at(3), '1.0');
      await tester.pumpAndSettle();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final h = (await dao.getHoldings()).single;
      expect(h.assetType, 'etf', reason: 'the product type stays 场内基金');
      expect(h.symbol, 'sz159985');
      expect(h.marketSource, 'sina');
      expect(h.categoryOverride, 'commodity', reason: 'the exposure is 商品');
      expect(effectiveCategoryOf(h), AssetCategory.commodity);

      await tester.pump(const Duration(milliseconds: 500));
      await db.close();
      await tester.pump();
    });
  });
}
