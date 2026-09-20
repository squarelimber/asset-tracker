import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/smooth_history.dart';

/// SQL schema as produced by schema version 9 (`category_override` on
/// holdings). Dates are stored as unix seconds, matching drift's INTEGER
/// storage. Columns added by an upgrade sit at the *end* of the table,
/// because `ALTER TABLE ... ADD COLUMN` appends — mirror that here or the
/// migration test exercises a shape production never has.
const _v9Ddl = [
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

/// Opens the app database on top of a hand-built v9 schema and seed data,
/// exercising the real v9 -> v10 upgrade path that production databases hit.
Future<AppDatabase> _openOnV9() async {
  final db = AppDatabase(
    NativeDatabase.memory(
      setup: (sqlite) {
        for (final ddl in _v9Ddl) {
          sqlite.execute(ddl);
        }
        sqlite.execute(
          "INSERT INTO accounts (id, name, type, currency, note, created_at, updated_at) "
          "VALUES (1, '旧账户', 'general', 'CNY', NULL, 1787000000, 1787000000);",
        );
        // Post-transfer state of the two accounts: 余额宝 was emptied into
        // 现金账户. On the write side that moved a proportional 8,000 of
        // principal, but the pre-v10 row can only state the raw 10,000
        // amount — which is exactly what the replay has to fall back to.
        sqlite.execute(
          "INSERT INTO holdings (id, account_id, name, asset_type, market_source, symbol, "
          "quantity, cost_price, latest_price, currency, cost_fx_rate, purchase_date, "
          "risk_level, note, archived, created_at, updated_at, category_override) "
          "VALUES (1, 1, '余额宝', 'moneyFund', 'manual', NULL, "
          "0, 0, 1, 'CNY', NULL, NULL, NULL, NULL, 0, 1787000000, 1788000000, 'cash');",
        );
        sqlite.execute(
          "INSERT INTO holdings (id, account_id, name, asset_type, market_source, symbol, "
          "quantity, cost_price, latest_price, currency, cost_fx_rate, purchase_date, "
          "risk_level, note, archived, created_at, updated_at, category_override) "
          "VALUES (2, 1, '现金账户', 'cash', 'manual', NULL, "
          "10000, 8000, 1, 'CNY', NULL, NULL, NULL, NULL, 0, 1787000000, 1788000000, NULL);",
        );
        // A transfer recorded before the new column existed.
        sqlite.execute(
          "INSERT INTO transactions (id, account_id, holding_id, cash_source_id, cash_target_id, "
          "type, quantity, price, amount, currency, occurred_at, note, cost_moved, updated_at) "
          "VALUES (1, 1, NULL, 1, 2, 'transfer_out', NULL, NULL, 10000, 'CNY', "
          "1787000000, NULL, 1, 1788000000);",
        );
        sqlite.execute('PRAGMA user_version = 9;');
      },
    ),
  );
  return db;
}

void main() {
  test('v9 -> v10 adds transactions.cost_moved_amount as NULL', () async {
    final db = await _openOnV9();
    final dao = AssetDao(db);

    // The seeded transfer survives untouched — it simply has no recorded
    // moved amount, which the replay must read as "unknown, use the legacy
    // amount" rather than "moved nothing".
    final txns = await dao.getTransactions();
    expect(txns, hasLength(1));
    expect(txns.single.costMovedAmount, isNull);
    expect(txns.single.costMoved, isTrue);
    expect(txns.single.amount, closeTo(10000, 1e-6));

    // Raw storage: the column exists and defaults to NULL.
    final userVersion = await db.customSelect('PRAGMA user_version;').getSingle();
    expect(userVersion.data.values.single, 10);

    final raw = await db
        .customSelect('SELECT cost_moved_amount FROM transactions WHERE id = 1;')
        .getSingle();
    expect(raw.data.values.single, isNull);

    // The upgrade must not rewrite any existing value.
    final keep = await db
        .customSelect(
            'SELECT amount, cost_moved, currency FROM transactions WHERE id = 1;')
        .getSingle();
    expect(keep.data.values, [10000.0, 1, 'CNY']);

    await db.close();
  });

  test('a rebuilt history keeps the legacy reading for pre-v10 rows', () async {
    final db = await _openOnV9();
    final dao = AssetDao(db);

    // No recorded moved amount => fall back to the raw amount. The replayed
    // pre-transfer principal is then the balance (10,000), not the true
    // 8,000 principal: that inaccuracy is inherent to the old rows and the
    // migration must not pretend otherwise.
    final h = (await dao.getHoldings()).firstWhere((x) => x.id == 1);
    final flows = await dao.getTransactionsForHolding(1);
    final principal = const SmoothHistoryCalculator().amountPrincipal(
      h,
      flows,
      from: DateTime(2026, 8, 1),
      to: DateTime(2026, 9, 20),
    );
    expect(principal.values.where((v) => v > 0).first, closeTo(10000, 1e-6));

    await db.close();
  });

  test('the new column round-trips through an update', () async {
    final db = await _openOnV9();
    final dao = AssetDao(db);

    final t = (await dao.getTransactions()).single;
    await dao.updateTransaction(t.copyWith(costMovedAmount: const Value(8000)));
    expect((await dao.getTransactions()).single.costMovedAmount, 8000);

    // And clearing it back to NULL restores the legacy reading.
    final saved = (await dao.getTransactions()).single;
    await dao.updateTransaction(saved.copyWith(costMovedAmount: const Value(null)));
    expect((await dao.getTransactions()).single.costMovedAmount, isNull);

    await db.close();
  });

  test('a v10 database created from scratch still works (no regression)',
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
      assetType: AssetType.cash.storageName,
      quantity: const Value(100),
      costPrice: const Value(100),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: 1,
      type: TransactionType.income.storageName,
      amount: 50,
      occurredAt: DateTime(2026, 9, 20),
      costMovedAmount: const Value(50),
    ));
    expect((await dao.getTransactions()).single.costMovedAmount, 50);
    await db.close();
  });
}
