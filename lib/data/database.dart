import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Accounts,
    Holdings,
    Transactions,
    PriceCache,
    Snapshots,
    AlertRules,
    AlertEvents,
    Settings,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 7;

  static QueryExecutor _openConnection() {
    // Web requires explicit web options: sqlite3.wasm and drift_worker.js
    // are bundled into web/ (see drift_flutter README). On native platforms
    // the web parameter is ignored.
    return driftDatabase(
      name: 'asset_tracker',
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Migration hooks for future schema versions.
  // ---------------------------------------------------------------------------
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v1 -> v2: add purchase_date to holdings.
          if (from < 2) {
            final db = m.database as AppDatabase;
            await m.addColumn(db.holdings, db.holdings.purchaseDate);
          }
          // v2 -> v3: add settings table.
          if (from < 3) {
            final db = m.database as AppDatabase;
            await m.createTable(db.settings);
          }
          // v3 -> v4: add cash linkage columns to transactions.
          if (from < 4) {
            final db = m.database as AppDatabase;
            await m.addColumn(db.transactions, db.transactions.cashSourceId);
            await m.addColumn(db.transactions, db.transactions.cashTargetId);
          }
          // v4 -> v5: (data-only migrations handled by DataMigrationService).
          // v5 -> v6: add risk_level to holdings.
          if (from < 6) {
            final db = m.database as AppDatabase;
            await m.addColumn(db.holdings, db.holdings.riskLevel);
          }
          // v6 -> v7: remove the overly broad transaction de-duplication
          // constraint. Two legitimate transactions can share the same
          // account, holding, type, timestamp and amount.
          if (from < 7) {
            final db = m.database as AppDatabase;
            // Older databases may not have cost_moved yet; add it before
            // rebuilding the table so the copy below is version-independent.
            try {
              await db.customStatement(
                'ALTER TABLE transactions '
                'ADD COLUMN cost_moved INTEGER NOT NULL DEFAULT 1;',
              );
            } catch (_) {
              // The column already exists.
            }
            await db.customStatement(
              'ALTER TABLE transactions RENAME TO transactions_tmp;',
            );
            await db.customStatement('''
              CREATE TABLE transactions (
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                account_id INTEGER NOT NULL REFERENCES accounts (id),
                holding_id INTEGER NULL REFERENCES holdings (id),
                cash_source_id INTEGER NULL REFERENCES holdings (id),
                cash_target_id INTEGER NULL REFERENCES holdings (id),
                type TEXT NOT NULL,
                quantity REAL NULL,
                price REAL NULL,
                amount REAL NOT NULL,
                currency TEXT NOT NULL DEFAULT 'CNY',
                occurred_at INTEGER NOT NULL,
                note TEXT NULL,
                cost_moved INTEGER NOT NULL DEFAULT 1
              );
            ''');
            await db.customStatement('''
              INSERT INTO transactions (
                id, account_id, holding_id, cash_source_id, cash_target_id,
                type, quantity, price, amount, currency, occurred_at, note,
                cost_moved
              )
              SELECT
                id, account_id, holding_id, cash_source_id, cash_target_id,
                type, quantity, price, amount, currency, occurred_at, note,
                cost_moved
              FROM transactions_tmp;
            ''');
            await db.customStatement('DROP TABLE transactions_tmp;');
          }
        },
      );
}
