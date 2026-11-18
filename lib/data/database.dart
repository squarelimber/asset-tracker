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
  int get schemaVersion => 13;

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

  Future<bool> _hasColumn(TableInfo table, GeneratedColumn column) async {
    final match = await customSelect(
      'SELECT 1 FROM pragma_table_info(?) WHERE name = ? COLLATE NOCASE',
      variables: [Variable(table.actualTableName), Variable(column.$name)],
    ).getSingleOrNull();
    return match != null;
  }

  Future<bool> _addMissingColumn(
    Migrator migrator,
    TableInfo table,
    GeneratedColumn column,
  ) async {
    if (await _hasColumn(table, column)) return false;
    await migrator.addColumn(table, column);
    return true;
  }

  Future<void> _ensureUpdatedAt(
    TableInfo table,
    GeneratedColumn updatedAt,
    GeneratedColumn fallback,
  ) async {
    final name = table.actualTableName;
    if (!await _hasColumn(table, updatedAt)) {
      await customStatement(
        'ALTER TABLE "$name" ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
      );
    }
    await customStatement(
      'UPDATE "$name" SET updated_at = "${fallback.$name}" WHERE updated_at = 0',
    );
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    // An earlier upgrade may have persisted DDL while user_version remained
    // old. Resume from the columns that actually exist, within a transaction.
    onUpgrade: (m, from, to) => transaction(() async {
      // v1 -> v2: add purchase_date to holdings.
      if (from < 2) {
        await _addMissingColumn(m, holdings, holdings.purchaseDate);
      }
      // v2 -> v3: add settings table.
      if (from < 3) {
        await m.createTable(settings);
      }
      // v3 -> v4: add cash linkage columns to transactions.
      if (from < 4) {
        await _addMissingColumn(m, transactions, transactions.cashSourceId);
        await _addMissingColumn(m, transactions, transactions.cashTargetId);
      }
      // v4 -> v5: (data-only migrations handled by DataMigrationService).
      // v5 -> v6: add risk_level to holdings.
      if (from < 6) {
        await _addMissingColumn(m, holdings, holdings.riskLevel);
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
        await _ensureUpdatedAt(
          accounts,
          accounts.updatedAt,
          accounts.createdAt,
        );
        await _ensureUpdatedAt(
          transactions,
          transactions.updatedAt,
          transactions.occurredAt,
        );
        await _ensureUpdatedAt(
          alertRules,
          alertRules.updatedAt,
          alertRules.createdAt,
        );
        await m.createTable(syncTombstones);
      }
      // v7 -> v8: add archived flag to holdings (sold-out products can be
      // archived instead of deleted, keeping their earnings-calendar
      // history). Constant default, so drift's addColumn is safe here.
      if (from < 8) {
        await _addMissingColumn(m, holdings, holdings.archived);
      }
      // v8 -> v9: allocation-category override on holdings, so a holding
      // can be categorised by its underlying exposure rather than its
      // product type (a 黄金ETF is an 场内基金 whose exposure is gold).
      // Nullable without a default, so drift's addColumn is safe.
      if (from < 9) {
        await _addMissingColumn(m, holdings, holdings.categoryOverride);
      }
      // v9 -> v10: record the invested amount a flow actually moved, so
      // the history replay stops guessing it from the raw amount (which
      // disagrees with the proportional write whenever the account has
      // unrealized gain). Nullable without a default, so drift's
      // addColumn is safe; existing rows stay NULL and the replay keeps
      // its legacy behaviour for them.
      if (from < 10) {
        await _addMissingColumn(m, transactions, transactions.costMovedAmount);
      }
      // v10 -> v11: mark the sell rows of internal redemptions whose
      // proceeds fund another holding. Constant default, so drift's
      // addColumn is safe; legacy rows stay false and keep behaving as
      // ordinary sells (their realized contribution is already baked
      // into the stored data).
      if (from < 11) {
        await _addMissingColumn(m, transactions, transactions.internalMove);
      }
      // v11 -> v12: remember whether a holding's principal was ever
      // explicitly recorded, so a genuine 0 stops doubling as "unset"
      // (and stops hiding the holding's full gain). Constant default, so
      // drift's addColumn is safe. Existing rows were all written under
      // the "0 means unset" rule, so backfill the flag from exactly that:
      // a positive cost was recorded, a 0 was not.
      if (from < 12 &&
          await _addMissingColumn(m, holdings, holdings.costRecorded)) {
        await customStatement(
          'UPDATE holdings SET cost_recorded = 1 WHERE cost_price > 0;',
        );
      }
      if (from < 13) {
        await _addMissingColumn(m, snapshots, snapshots.holdingValues);
      }
    }),
  );
}
