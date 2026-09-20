import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_category.dart';

/// SQL schema as produced by schema version 8 (`archived` on holdings).
/// Dates are stored as unix seconds, matching drift's INTEGER storage.
const _v8Ddl = [
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

/// Opens the app database on top of a hand-built v8 schema and seed data,
/// exercising the real v8 -> v9 upgrade path that production databases hit.
Future<AppDatabase> _openOnV8() async {
  final db = AppDatabase(
    NativeDatabase.memory(
      setup: (sqlite) {
        for (final ddl in _v8Ddl) {
          sqlite.execute(ddl);
        }
        sqlite.execute(
          "INSERT INTO accounts (id, name, type, currency, note, created_at, updated_at) "
          "VALUES (1, '旧账户', 'general', 'CNY', NULL, 1787000000, 1787000000);",
        );
        // A plain 场内基金 with no category override: its allocation category
        // must keep being derived from the asset type after the migration.
        sqlite.execute(
          "INSERT INTO holdings (id, account_id, name, asset_type, market_source, symbol, "
          "quantity, cost_price, latest_price, currency, cost_fx_rate, purchase_date, "
          "risk_level, note, archived, created_at, updated_at) "
          "VALUES (1, 1, '沪深300ETF', 'etf', 'sina', 'sh510300', "
          "1000, 3.5, 4.0, 'CNY', NULL, NULL, NULL, NULL, 0, 1787000000, 1788000000);",
        );
        sqlite.execute('PRAGMA user_version = 8;');
      },
    ),
  );
  return db;
}

void main() {
  test('v8 -> v9 migration adds holdings.category_override as NULL', () async {
    final db = await _openOnV8();
    final dao = AssetDao(db);

    // The seeded row survives and has no override — i.e. it keeps the old,
    // type-derived categorisation rather than being filed anywhere new.
    final holdings = await dao.getHoldings();
    expect(holdings, hasLength(1));
    expect(holdings.single.categoryOverride, isNull);
    expect(effectiveCategoryOf(holdings.single), AssetCategory.equity);

    // Raw storage: the column exists, is nullable and defaults to NULL.
    final userVersion = await db.customSelect('PRAGMA user_version;').getSingle();
    expect(userVersion.data.values.single, greaterThanOrEqualTo(9));

    final raw = await db
        .customSelect('SELECT category_override FROM holdings WHERE id = 1;')
        .getSingle();
    expect(raw.data.values.single, isNull);

    // The upgrade must not rewrite any existing value: the round-trip build
    // of the row would drop an unknown column, so check the whole row too.
    final name = await db
        .customSelect('SELECT symbol, latest_price FROM holdings WHERE id = 1;')
        .getSingle();
    expect(name.data.values, ['sh510300', 4.0]);

    await db.close();
  });

  test('the override survives an update round-trip', () async {
    final db = await _openOnV8();
    final dao = AssetDao(db);

    final h = (await dao.getHoldings()).single;
    // File the ETF under 商品 (a 豆粕ETF-style holding) and save.
    await dao.updateHolding(h.copyWith(categoryOverride: const Value('commodity')));
    final saved = (await dao.getHoldings()).single;
    expect(saved.categoryOverride, 'commodity');
    expect(effectiveCategoryOf(saved), AssetCategory.commodity);
    // The product type is untouched — 场内基金 is still 场内基金.
    expect(AssetType.fromStorage(saved.assetType), AssetType.etf);

    // Clearing it goes back to the type-derived category.
    await dao.updateHolding(saved.copyWith(categoryOverride: const Value(null)));
    expect(
      effectiveCategoryOf((await dao.getHoldings()).single),
      AssetCategory.equity,
    );

    await db.close();
  });

  test('a v9 database created from scratch still works (no regression)',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    await dao.createAccount(AccountsCompanion.insert(
      name: '全新库',
      type: 'general',
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: 1,
      name: '豆粕ETF',
      assetType: 'etf',
      symbol: const Value('sz159985'),
      quantity: const Value(100),
      categoryOverride: const Value('commodity'),
    ));
    expect(
      effectiveCategoryOf((await dao.getHoldings()).single),
      AssetCategory.commodity,
    );
    await db.close();
  });
}
