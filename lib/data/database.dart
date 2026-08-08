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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

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
          // Schema v2+ migrations go here.
        },
      );
}
