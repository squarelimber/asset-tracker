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
    SyncTombstones,
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
          // v6 -> v7: multi-device sync support — updatedAt on every synced
          // table (backfilled from createdAt) and the tombstone table.
          //
          // NOTE: drift's addColumn() emits `DEFAULT CAST(strftime(...))`
          // for dateTime().withDefault(currentDateAndTime) columns, which
          // SQLite rejects for ALTER TABLE ADD COLUMN (non-constant
          // default). Add the column manually with a constant default and
          // backfill real timestamps.
          if (from < 7) {
            final db = m.database as AppDatabase;
            await customStatement(
              'ALTER TABLE accounts ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;',
            );
            await customStatement(
              'ALTER TABLE transactions ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;',
            );
            await customStatement(
              'ALTER TABLE alert_rules ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;',
            );
            await customStatement(
              'UPDATE accounts SET updated_at = created_at;',
            );
            await customStatement(
              'UPDATE transactions SET updated_at = occurred_at;',
            );
            await customStatement(
              'UPDATE alert_rules SET updated_at = created_at;',
            );
            await m.createTable(db.syncTombstones);
          }
        },
      );
}
