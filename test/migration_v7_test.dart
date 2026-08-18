import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';

/// SQL schema as produced by schema version 6 (before the multi-device
/// sync migration added `updated_at` columns and the tombstone table).
/// Dates are stored as unix seconds, matching drift's INTEGER storage.
const _v6Ddl = [
  '''
  CREATE TABLE accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    currency TEXT NOT NULL DEFAULT 'CNY',
    note TEXT,
    created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER))
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
    created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
    updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER))
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
    cost_moved INTEGER NOT NULL DEFAULT 1
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
    created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER))
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
];

/// Opens the app database on top of a hand-built v6 schema and seed data,
/// exercising the real v6 -> v7 upgrade path that production databases hit.
Future<AppDatabase> _openOnV6() async {
  final db = AppDatabase(
    NativeDatabase.memory(
      setup: (sqlite) {
        for (final ddl in _v6Ddl) {
          sqlite.execute(ddl);
        }
        // Two accounts with distinct creation times.
        sqlite.execute(
          "INSERT INTO accounts (id, name, type, currency, note, created_at) "
          "VALUES (1, '旧账户', 'general', 'CNY', NULL, 1787000000);",
        );
        sqlite.execute(
          "INSERT INTO accounts (id, name, type, currency, note, created_at) "
          "VALUES (2, '新账户', 'general', 'CNY', NULL, 1788000000);",
        );
        sqlite.execute(
          "INSERT INTO alert_rules (id, type, name, params, enabled, created_at) "
          "VALUES (1, 'concentration', '集中度', '{}', 1, 1786500000);",
        );
        // Mark the database as schema version 6 so drift runs the upgrade.
        sqlite.execute('PRAGMA user_version = 6;');
      },
    ),
  );
  return db;
}

void main() {
  test('v6 -> v7 migration adds updated_at columns and backfills them', () async {
    final db = await _openOnV6();
    final dao = AssetDao(db);

    final accounts = await dao.getAccounts();
    expect(accounts, hasLength(2));
    for (final a in accounts) {
      // Backfilled from created_at.
      expect(a.updatedAt, a.createdAt);
    }

    // Raw storage is unix seconds: confirm the columns really exist.
    final userVersion = await db
        .customSelect('PRAGMA user_version;')
        .getSingle();
    expect(userVersion.data.values.single, 7);

    // The tombstone table was created by the migration.
    final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sync_tombstones';",
    ).get();
    expect(tables, isNotEmpty);

    // Writes still work after the migration.
    await dao.createAccount(AccountsCompanion.insert(
      name: '新账户2',
      type: 'general',
    ));
    expect(await dao.getAccounts(), hasLength(3));
    await db.close();
  });

  test('v7 database created from scratch still works (no regression)', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    await dao.createAccount(AccountsCompanion.insert(
      name: '全新库',
      type: 'general',
    ));
    final accounts = await dao.getAccounts();
    expect(accounts.single.name, '全新库');
    await db.close();
  });
}
