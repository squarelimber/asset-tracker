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
}
