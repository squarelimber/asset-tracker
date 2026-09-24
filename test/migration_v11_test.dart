import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';

/// SQL schema as produced by schema version 10 (`cost_moved_amount` on
/// transactions, no `internal_move` yet). Dates are stored as unix seconds,
/// matching drift's INTEGER storage. Columns added by an upgrade sit at the
/// *end* of the table, because `ALTER TABLE ... ADD COLUMN` appends — mirror
/// that here or the migration test exercises a shape production never has.
const _v10Ddl = [
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
    cost_moved_amount REAL
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

/// Opens the app database on top of a hand-built v10 schema and seed data,
/// exercising the real v10 -> v11 upgrade path that production databases hit.
Future<AppDatabase> _openOnV10() async {
  final db = AppDatabase(
    NativeDatabase.memory(
      setup: (sqlite) {
        for (final ddl in _v10Ddl) {
          sqlite.execute(ddl);
        }
        sqlite.execute(
          "INSERT INTO accounts (id, name, type, currency, note, created_at, updated_at) "
          "VALUES (1, '旧账户', 'general', 'CNY', NULL, 1787000000, 1787000000);",
        );
        // A sell row recorded before the internal-redemption marker existed
        // (e.g. a「赎回购买」from the old build): it stays an ordinary sell
        // and keeps its legacy realized reading.
        sqlite.execute(
          "INSERT INTO holdings (id, account_id, name, asset_type, market_source, symbol, "
          "quantity, cost_price, latest_price, currency, cost_fx_rate, purchase_date, "
          "risk_level, note, archived, created_at, updated_at, category_override) "
          "VALUES (1, 1, '月月宝', 'bank_wealth', 'forex', NULL, "
          "1000, 1, 2, 'CNY', NULL, NULL, NULL, NULL, 0, 1787000000, 1788000000, NULL);",
        );
        sqlite.execute(
          "INSERT INTO transactions (id, account_id, holding_id, cash_source_id, cash_target_id, "
          "type, quantity, price, amount, currency, occurred_at, note, cost_moved, updated_at, cost_moved_amount) "
          "VALUES (1, 1, 1, NULL, NULL, 'sell', 500, 2, 1000, 'CNY', "
          "1787000000, '赎回购买 五年国债ETF', 1, 1788000000, 500);",
        );
        sqlite.execute('PRAGMA user_version = 10;');
      },
    ),
  );
  return db;
}

void main() {
  test('v10 -> v11 adds transactions.internal_move defaulting to false', () async {
    final db = await _openOnV10();
    final dao = AssetDao(db);

    // The seeded sell row survives and reads as a non-internal sell.
    final txns = await dao.getTransactions();
    expect(txns, hasLength(1));
    expect(txns.single.internalMove, isFalse);
    expect(txns.single.costMovedAmount, closeTo(500, 1e-6));

    // Raw storage: the column exists and defaults to 0.
    final userVersion = await db.customSelect('PRAGMA user_version;').getSingle();
    expect(userVersion.data.values.single, 11);

    final raw = await db
        .customSelect('SELECT internal_move FROM transactions WHERE id = 1;')
        .getSingle();
    expect(raw.data.values.single, 0);

    // The upgrade must not rewrite any existing value.
    final keep = await db
        .customSelect(
            'SELECT amount, cost_moved, cost_moved_amount FROM transactions WHERE id = 1;')
        .getSingle();
    expect(keep.data.values, [1000.0, 1, 500.0]);

    await db.close();
  });

  test('internal_move round-trips through an update', () async {
    final db = await _openOnV10();
    final dao = AssetDao(db);

    final t = (await dao.getTransactions()).single;
    await dao.updateTransaction(t.copyWith(internalMove: true));
    expect((await dao.getTransactions()).single.internalMove, isTrue);

    await db.close();
  });

  test('a v11 database created from scratch still works (no regression)',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    await dao.createAccount(AccountsCompanion.insert(
      name: '全新库',
      type: 'general',
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: 1,
      name: '现金',
      assetType: 'bank_deposit',
      quantity: const Value(100),
      costPrice: const Value(100),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: 1,
      type: 'income',
      amount: 50,
      occurredAt: DateTime(2026, 9, 20),
      costMovedAmount: const Value(50),
      internalMove: const Value(true),
    ));
    expect((await dao.getTransactions()).single.internalMove, isTrue);
    await db.close();
  });
}