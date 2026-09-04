import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';

/// SQL schema as produced by schema version 7 (multi-device sync:
/// `updated_at` on accounts/transactions/alert_rules plus the tombstone
/// table). Dates are stored as unix seconds, matching drift's INTEGER storage.
const _v7Ddl = [
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
    cost_moved INTEGER NOT NULL DEFAULT 1,
    updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER))
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

/// Opens the app database on top of a hand-built v7 schema and seed data,
/// exercising the real v7 -> v8 upgrade path that production databases hit.
Future<AppDatabase> _openOnV7() async {
  final db = AppDatabase(
    NativeDatabase.memory(
      setup: (sqlite) {
        for (final ddl in _v7Ddl) {
          sqlite.execute(ddl);
        }
        sqlite.execute(
          "INSERT INTO accounts (id, name, type, currency, note, created_at, updated_at) "
          "VALUES (1, '旧账户', 'general', 'CNY', NULL, 1787000000, 1787000000);",
        );
        sqlite.execute(
          "INSERT INTO holdings (id, account_id, name, asset_type, market_source, symbol, "
          "quantity, cost_price, latest_price, currency, cost_fx_rate, purchase_date, "
          "risk_level, note, created_at, updated_at) "
          "VALUES (1, 1, '某基金', 'mutual_fund', 'eastmoney', '110022', "
          "100, 10, 15, 'CNY', NULL, NULL, NULL, NULL, 1787000000, 1788000000);",
        );
        // Mark the database as schema version 7 so drift runs the upgrade.
        sqlite.execute('PRAGMA user_version = 7;');
      },
    ),
  );
  return db;
}

void main() {
  test('v7 -> v8 migration adds holdings.archived defaulting to false', () async {
    final db = await _openOnV7();
    final dao = AssetDao(db);

    // The seeded row survives the migration and reads archived = false.
    final holdings = await dao.getHoldings();
    expect(holdings, hasLength(1));
    expect(holdings.single.archived, isFalse);

    // Raw storage: the column exists and the default is 0.
    final userVersion = await db
        .customSelect('PRAGMA user_version;')
        .getSingle();
    expect(userVersion.data.values.single, 8);

    final archivedValue = await db
        .customSelect('SELECT archived FROM holdings WHERE id = 1;')
        .getSingle();
    expect(archivedValue.data.values.single, 0);

    // setArchived flips the flag and bumps updated_at.
    final now = DateTime.now();
    await dao.setArchived(1, true, now: now);
    final archived = await dao.getHolding(1);
    expect(archived!.archived, isTrue);
    expect(archived.updatedAt, now);

    // Restore works too.
    await dao.setArchived(1, false, now: now);
    expect((await dao.getHolding(1))!.archived, isFalse);

    // Writes still work after the migration.
    await dao.createAccount(AccountsCompanion.insert(
      name: '新账户2',
      type: 'general',
    ));
    expect(await dao.getAccounts(), hasLength(2));
    await db.close();
  });

  test('v8 database created from scratch still works (no regression)', () async {
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
