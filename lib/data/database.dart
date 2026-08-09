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
  int get schemaVersion => 4;

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'asset_tracker');
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
        },
      );
}
