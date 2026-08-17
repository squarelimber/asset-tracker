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

  test('holdings rebuild retains all current schema columns', () async {
    await DataMigrationService(db).run();
    final rows = await db.customSelect('PRAGMA table_info(holdings)').get();
    final columns = rows.map((row) => row.data['name']).toSet();
    expect(columns, containsAll(<String>{
      'cost_fx_rate',
      'purchase_date',
      'risk_level',
    }));
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

  test('liability holdings get costPrice reset to 1', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试',
      type: 'general',
    ));
    // Old buggy format: costPrice stored the balance instead of unit price 1.
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '信用卡',
      assetType: 'liability',
      marketSource: const Value('manual'),
      quantity: const Value(3200),
      costPrice: const Value(3200),
      latestPrice: const Value(1),
    ));
    // A stock holding must NOT be touched.
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
    final card = holdings.firstWhere((h) => h.name == '信用卡');
    expect(card.costPrice, 1);
    final fund = holdings.firstWhere((h) => h.name == '基金');
    expect(fund.costPrice, 2.5); // untouched
  });

  test('legacy transfers are marked and cash costs calibrated', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试',
      type: 'general',
    ));
    final cash = await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '天天宝',
      assetType: 'liquid_wealth',
      marketSource: const Value('manual'),
      quantity: const Value(96071.69),
      costPrice: const Value(96252.85), // legacy transfer left cost unsynced
      latestPrice: const Value(1),
    ));
    final loan = await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '信用卡',
      assetType: 'liability',
      marketSource: const Value('manual'),
      quantity: const Value(181.16),
      costPrice: const Value(1),
      latestPrice: const Value(1),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: accountId,
      type: 'transfer_out',
      amount: 181.16,
      cashSourceId: Value(cash),
      cashTargetId: Value(loan),
      occurredAt: DateTime(2026, 8, 1),
    ));

    await DataMigrationService(db).run();

    final txns = await dao.getTransactions();
    expect(txns.single.costMoved, isFalse); // legacy transfer marked
    // Calibrated to cost = quantity + net outflow (the legacy transfer
    // amount stays invested until the flow is removed).
    final h = (await dao.getHolding(cash))!;
    expect(h.costPrice, closeTo(h.quantity + 181.16, 1e-9));
  });

  test('corrupted cash costs are restored by the transfer migration', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试',
      type: 'general',
    ));
    final cash = await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '现金',
      assetType: 'savings',
      marketSource: const Value('manual'),
      quantity: const Value(7000),
      costPrice: const Value(9500), // corrupted: should be 7000 + 3000
      latestPrice: const Value(1),
    ));
    final loan = await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '贷款',
      assetType: 'liability',
      marketSource: const Value('manual'),
      quantity: const Value(3000),
      costPrice: const Value(1),
      latestPrice: const Value(1),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: accountId,
      type: 'transfer_out',
      amount: 3000,
      cashSourceId: Value(cash),
      cashTargetId: Value(loan),
      occurredAt: DateTime(2026, 8, 1),
    ));

    await DataMigrationService(db).run();

    final h = (await dao.getHolding(cash))!;
    expect(h.costPrice, closeTo(10000, 1e-9)); // quantity + net outflow
  });

  test('512480 v8+v9 net effect leaves already-adjusted holdings unchanged', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试',
      type: 'general',
    ));
    // Post-split values: the v8 x2 fix (wrong for this data) is undone by
    // the v9 rollback, so the final state equals the input.
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '半导体',
      assetType: 'etf',
      marketSource: const Value('sina'),
      symbol: const Value('sh512480'),
      quantity: const Value(109300),
      costPrice: const Value(0.706),
      latestPrice: const Value(1.331),
    ));
    // Another holding must NOT be touched.
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
    final semi = holdings.firstWhere((h) => h.name == '半导体');
    expect(semi.quantity, 109300);
    expect(semi.costPrice, closeTo(0.706, 1e-9));
    final fund = holdings.firstWhere((h) => h.name == '基金');
    expect(fund.quantity, 100); // untouched
    expect(fund.costPrice, 2.5);
    // History rebuild marker set so snapshots reflect the corrected values.
    final dirty = await dao.getSetting('history_sync_dirty');
    expect(dirty, '1');
  });

  test('v9 rollback restores an already post-split 512480 holding', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试',
      type: 'general',
    ));
    // Post-split values (user had already updated before the v8 fix ran).
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '半导体',
      assetType: 'etf',
      marketSource: const Value('sina'),
      symbol: const Value('sh512480'),
      quantity: const Value(109300),
      costPrice: const Value(0.706),
      latestPrice: const Value(1.068),
    ));

    // First run applies v8 (wrong for this data) then v9 restores it.
    await DataMigrationService(db).run();

    final h = (await dao.getHolding(
      (await dao.getHoldings()).single.id,
    ))!;
    expect(h.quantity, 109300); // v8 doubled, v9 rolled back
    expect(h.costPrice, closeTo(0.706, 1e-9));
  });

  test('v10 adds cost_fx_rate and backfills the known USD holding', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试',
      type: 'general',
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '汇利日盈6号A',
      assetType: 'bank_wealth',
      marketSource: const Value('manual'),
      symbol: const Value('Y05A9W10006A'),
      quantity: const Value(14375.56),
      costPrice: const Value(1.098739),
      latestPrice: const Value(1.11697),
      currency: const Value('USD'),
    ));
    // A CNY holding must NOT get a rate.
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '现金',
      assetType: 'savings',
      marketSource: const Value('manual'),
      quantity: const Value(1000),
      costPrice: const Value(1000),
      latestPrice: const Value(1),
    ));

    await DataMigrationService(db).run();

    final holdings = await dao.getHoldings();
    final usd = holdings.firstWhere((h) => h.name == '汇利日盈6号A');
    expect(usd.costFxRate, closeTo(6.95, 1e-9));
    final cny = holdings.firstWhere((h) => h.name == '现金');
    expect(cny.costFxRate, isNull);
    final dirty = await dao.getSetting('history_sync_dirty');
    expect(dirty, '1');
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
