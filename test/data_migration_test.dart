import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/data_migration_service.dart';

void main() {
  late AppDatabase db;
  late AssetDao dao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('legacy cash holdings get costPrice rewritten to quantity', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试',
      type: 'general',
    ));
    // Legacy format: quantity=amount, costPrice=1, latestPrice=1.
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '现金',
      assetType: 'savings',
      marketSource: const Value('manual'),
      quantity: const Value(10000),
      costPrice: const Value(1),
      latestPrice: const Value(1),
    ));
    // A fund holding must NOT be touched.
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '基金',
      assetType: 'mutual_fund',
      marketSource: const Value('eastmoney'),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: const Value(2.9),
    ));

    await DataMigrationService(db).run();

    final holdings = await dao.getHoldings();
    final cash = holdings.firstWhere((h) => h.name == '现金');
    expect(cash.costPrice, 10000);
    final fund = holdings.firstWhere((h) => h.name == '基金');
    expect(fund.costPrice, 2.5); // untouched
  });

  test('migration runs only once', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试',
      type: 'general',
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '现金',
      assetType: 'savings',
      marketSource: const Value('manual'),
      quantity: const Value(500),
      costPrice: const Value(1),
      latestPrice: const Value(1),
    ));

    await DataMigrationService(db).run();
    // User then edits the holding to a real invested amount.
    final holdings = await dao.getHoldings();
    final stmt = db.update(db.holdings)..where((t) => t.id.equals(holdings.single.id));
    await stmt.write(const HoldingsCompanion(costPrice: Value(300)));

    // Second run must not rewrite it back to quantity.
    await DataMigrationService(db).run();
    final after = await dao.getHoldings();
    expect(after.single.costPrice, 300);
  });

  test('non-legacy cash holdings are left alone', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试',
      type: 'general',
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '现金',
      assetType: 'savings',
      marketSource: const Value('manual'),
      quantity: const Value(5000),
      costPrice: const Value(4000), // already amount-based semantics
      latestPrice: const Value(1),
    ));

    await DataMigrationService(db).run();
    final holdings = await dao.getHoldings();
    expect(holdings.single.costPrice, 4000);
  });

  test('gold holdings without a symbol get AU99.99', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试',
      type: 'general',
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '积存金',
      assetType: 'gold',
      marketSource: const Value('sge'),
      quantity: const Value(70.9),
      costPrice: const Value(1063),
      latestPrice: const Value(941.92),
    ));
    // A fund without symbol must NOT be touched.
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '现金宝',
      assetType: 'liquid_wealth',
      marketSource: const Value('manual'),
      quantity: const Value(500),
      costPrice: const Value(500),
      latestPrice: const Value(1),
    ));

    await DataMigrationService(db).run();
    final holdings = await dao.getHoldings();
    final gold = holdings.firstWhere((h) => h.name == '积存金');
    expect(gold.symbol, 'AU99.99');
    final wealth = holdings.firstWhere((h) => h.name == '现金宝');
    expect(wealth.symbol, isNull);
  });

  test('rebuild drops the legacy UNIQUE(symbol) constraint', () async {
    // Simulate a v1-era database: holdings table with UNIQUE(symbol).
    await db.customStatement(
      'ALTER TABLE holdings RENAME TO holdings_v1;'
      "CREATE TABLE holdings (id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "
      "account_id INTEGER NOT NULL, name TEXT NOT NULL, asset_type TEXT NOT NULL, "
      "market_source TEXT NOT NULL DEFAULT 'manual', symbol TEXT NULL, "
      "quantity REAL NOT NULL DEFAULT 0.0, cost_price REAL NOT NULL DEFAULT 0.0, "
      "latest_price REAL NOT NULL DEFAULT 0.0, currency TEXT NOT NULL DEFAULT 'CNY', "
      "note TEXT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, "
      "purchase_date INTEGER NULL, UNIQUE (symbol));"
      'INSERT INTO holdings (account_id, name, asset_type, symbol, quantity, cost_price, latest_price, created_at, updated_at) '
      "VALUES (0, '旧基金', 'mutual_fund', '110022', 100, 1.0, 1.0, 0, 0);"
      'DROP TABLE holdings_v1;',
    );

    await DataMigrationService(db).run();

    // Same symbol can now be inserted twice (the old constraint is gone).
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: 0,
      name: '新基金',
      assetType: 'mutual_fund',
      marketSource: const Value('eastmoney'),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(1.5),
      latestPrice: const Value(1.6),
      purchaseDate: Value(DateTime(2026, 7, 1)),
    ));

    final holdings = await dao.getHoldings();
    expect(holdings, hasLength(2));
    expect(holdings.map((h) => h.symbol).toSet(), {'110022'});
  });
}
