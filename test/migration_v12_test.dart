import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_cost.dart';

/// SQL schema as produced by schema version 11 (`internal_move` on
/// transactions, no `cost_recorded` yet). Dates are stored as unix seconds,
/// matching drift's INTEGER storage. Columns added by an upgrade sit at the
/// *end* of the table, because `ALTER TABLE ... ADD COLUMN` appends — mirror
/// that here or the migration test exercises a shape production never has.
const _v11Ddl = [
  '''
  CREATE TABLE accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    currency TEXT NOT NULL DEFAULT 'CNY',
    note TEXT,
    created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER))
  );
  ''',
  '''
  CREATE TABLE holdings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL REFERENCES accounts(id),
    name TEXT NOT NULL,
    asset_type TEXT NOT NULL,
    market_source TEXT NOT NULL DEFAULT 'manual',
    symbol TEXT,
    quantity REAL NOT NULL DEFAULT 0,
    cost_price REAL NOT NULL DEFAULT 0,
    latest_price REAL NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'CNY',
    cost_fx_rate REAL,
    purchase_date INTEGER,
    risk_level TEXT,
    note TEXT,
    archived INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    category_override TEXT
  );
  ''',
  '''
  CREATE TABLE transactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL REFERENCES accounts(id),
    holding_id INTEGER REFERENCES holdings(id),
    cash_source_id INTEGER REFERENCES holdings(id),
    cash_target_id INTEGER REFERENCES holdings(id),
    type TEXT NOT NULL,
    quantity REAL,
    price REAL,
    amount REAL NOT NULL,
    currency TEXT NOT NULL DEFAULT 'CNY',
    occurred_at INTEGER NOT NULL,
    note TEXT,
    cost_moved INTEGER NOT NULL DEFAULT 1,
    updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    cost_moved_amount REAL,
    internal_move INTEGER NOT NULL DEFAULT 0
  );
  ''',
  '''
  CREATE TABLE price_cache (
    symbol TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    price REAL NOT NULL,
    currency TEXT NOT NULL DEFAULT 'CNY',
    prev_close REAL,
    change REAL,
    change_pct REAL,
    fetched_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER))
  );
  ''',
  '''
  CREATE TABLE snapshots (
    date TEXT NOT NULL,
    currency TEXT NOT NULL DEFAULT 'CNY',
    total_value REAL NOT NULL,
    total_cost REAL NOT NULL,
    liabilities REAL NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    PRIMARY KEY (date, currency)
  );
  ''',
  '''
  CREATE TABLE alert_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL,
    name TEXT NOT NULL,
    params TEXT NOT NULL DEFAULT '{}',
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER))
  );
  ''',
  '''
  CREATE TABLE alert_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_id INTEGER NOT NULL REFERENCES alert_rules(id),
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    triggered_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER))
  );
  ''',
  '''
  CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT ''
  );
  ''',
  '''
  CREATE TABLE sync_tombstones (
    "table" TEXT NOT NULL,
    row_key TEXT NOT NULL,
    deleted_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    PRIMARY KEY ("table", row_key)
  );
  ''',
];

/// Opens the app database on top of a hand-built v11 schema and seed data,
/// exercising the real v11 -> v12 upgrade path that production databases hit.
///
/// Two amount-based holdings: one with a positive recorded cost, one with a
/// bare 0 — the two shapes the old "0 means unset" rule left behind.
Future<AppDatabase> _openOnV11() async {
  final db = AppDatabase(
    NativeDatabase.memory(
      setup: (sqlite) {
        for (final ddl in _v11Ddl) {
          sqlite.execute(ddl);
        }
        sqlite.execute(
          "INSERT INTO accounts (id, name, type, currency, note, created_at, updated_at) "
          "VALUES (1, '旧账户', 'general', 'CNY', NULL, 1787000000, 1787000000);",
        );
        sqlite.execute(
          "INSERT INTO holdings (id, account_id, name, asset_type, market_source, symbol, "
          "quantity, cost_price, latest_price, currency, cost_fx_rate, purchase_date, "
          "risk_level, note, archived, created_at, updated_at, category_override) "
          "VALUES (1, 1, '有本金的现金', 'cash', 'manual', NULL, "
          "10000, 9000, 1, 'CNY', NULL, NULL, NULL, NULL, 0, 1787000000, 1788000000, NULL);",
        );
        sqlite.execute(
          "INSERT INTO holdings (id, account_id, name, asset_type, market_source, symbol, "
          "quantity, cost_price, latest_price, currency, cost_fx_rate, purchase_date, "
          "risk_level, note, archived, created_at, updated_at, category_override) "
          "VALUES (2, 1, '未记录本金', 'bank_deposit', 'manual', NULL, "
          "5000, 0, 1, 'CNY', NULL, NULL, NULL, NULL, 0, 1787000000, 1788000000, NULL);",
        );
        sqlite.execute('PRAGMA user_version = 11;');
      },
    ),
  );
  return db;
}

void main() {
  test('v11 -> v12 backfills cost_recorded from the old "0 means unset" rule',
      () async {
    final db = await _openOnV11();
    final dao = AssetDao(db);

    final holdings = await dao.getHoldings();
    expect(holdings, hasLength(2));
    final withCost = holdings.firstWhere((h) => h.id == 1);
    final unset = holdings.firstWhere((h) => h.id == 2);

    // A positive cost had been recorded; a bare 0 had not.
    expect(withCost.costRecorded, isTrue);
    expect(unset.costRecorded, isFalse);

    // And both keep reading exactly as before the migration.
    expect(effectiveCostOf(withCost), closeTo(9000, 1e-6));
    expect(effectiveCostOf(unset), closeTo(5000, 1e-6));

    // Raw storage: the column exists, is at the end, and version bumped.
    final userVersion =
        await db.customSelect('PRAGMA user_version;').getSingle();
    expect(userVersion.data.values.single, 12);

    final raw = await db
        .customSelect('SELECT cost_recorded FROM holdings WHERE id = 1;')
        .getSingle();
    expect(raw.data.values.single, 1);
    final rawUnset = await db
        .customSelect('SELECT cost_recorded FROM holdings WHERE id = 2;')
        .getSingle();
    expect(rawUnset.data.values.single, 0);

    await db.close();
  });

  test('an explicitly recorded zero reads as a real zero principal', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    await dao.createAccount(
        AccountsCompanion.insert(name: 'A', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: 1,
      name: '朋友赠予',
      assetType: 'bank_deposit',
      quantity: const Value(10000),
      costPrice: const Value(0),
      costRecorded: const Value(true),
    ));

    final h = (await dao.getHoldings()).single;
    // Real zero principal: the whole balance is gain, not a fabricated 0.
    expect(effectiveCostOf(h), 0);

    await db.close();
  });

  test('a v12 database created from scratch still works (no regression)',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    await dao.createAccount(
        AccountsCompanion.insert(name: '全新库', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: 1,
      name: '现金',
      assetType: 'bank_deposit',
      quantity: const Value(100),
      costPrice: const Value(100),
    ));
    final h = (await dao.getHoldings()).single;
    expect(h.costRecorded, isFalse);
    expect(effectiveCostOf(h), 100);
    await db.close();
  });
}
