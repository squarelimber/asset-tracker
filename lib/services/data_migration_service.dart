import 'package:drift/drift.dart';

import '../data/database.dart';

/// One-time data migrations that run after the schema is in place.
///
/// v3: convert legacy cash / bank deposit holdings (recorded in the old
/// price model: quantity=amount, costPrice=1, latestPrice=1) to the
/// amount-based semantics (costPrice = cumulative invested).
class DataMigrationService {
  DataMigrationService(this._db);

  final AppDatabase _db;

  static const _amountBasedMigrated = 'amount_based_migrated_v3';

  /// Fills the default market code (AU99.99) for gold holdings that were
  /// created without one, so they auto-sync like other market-linked assets.
  static const _goldSymbolMigrated = 'gold_symbol_filled';

  /// Rebuilds the holdings table without the legacy UNIQUE(symbol)
  /// constraint (present in databases created at schema v1).
  static const _holdingsRebuilt = 'holdings_rebuilt_v5';

  /// Liability holdings store the outstanding balance in quantity with a
  /// unit price of 1; older records stored costPrice = balance, which made
  /// the cost (quantity x costPrice) explode. Reset those to 1.
  static const _liabilityCostFixed = 'liability_cost_fixed_v6';

  /// Runs all pending one-time migrations. Safe to call on every launch.
  Future<void> run() async {
    await _migrateAmountBased();
    await _migrateGoldSymbol();
    await _rebuildHoldingsTable();
    await _migrateLiabilityCost();
  }

  /// SQLite cannot drop a UNIQUE constraint without rebuilding the table.
  /// Recreate `holdings` identically but without UNIQUE(symbol) so the same
  /// market code can exist across multiple holdings/accounts.
  Future<void> _rebuildHoldingsTable() async {
    final marker = await _getSetting(_holdingsRebuilt);
    if (marker != null) return;

    await _db.customStatement('ALTER TABLE holdings RENAME TO holdings_tmp;');
    await _db.customStatement('''
      CREATE TABLE holdings (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        account_id INTEGER NOT NULL REFERENCES accounts (id),
        name TEXT NOT NULL,
        asset_type TEXT NOT NULL,
        market_source TEXT NOT NULL DEFAULT 'manual',
        symbol TEXT NULL,
        quantity REAL NOT NULL DEFAULT 0.0,
        cost_price REAL NOT NULL DEFAULT 0.0,
        latest_price REAL NOT NULL DEFAULT 0.0,
        currency TEXT NOT NULL DEFAULT 'CNY',
        note TEXT NULL,
        created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
        updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
        purchase_date INTEGER NULL
      );
    ''');
    await _db.customStatement('''
      INSERT INTO holdings (id, account_id, name, asset_type, market_source, symbol,
                            quantity, cost_price, latest_price, currency, note,
                            created_at, updated_at, purchase_date)
      SELECT id, account_id, name, asset_type, market_source, symbol,
             quantity, cost_price, latest_price, currency, note,
             created_at, updated_at, purchase_date
      FROM holdings_tmp;
    ''');
    await _db.customStatement('DROP TABLE holdings_tmp;');

    await _setSetting(_holdingsRebuilt, '${DateTime.now().millisecondsSinceEpoch}');
  }

  Future<void> _migrateAmountBased() async {
    final marker = await _getSetting(_amountBasedMigrated);
    if (marker != null) return;

    final legacy = await (_db.select(_db.holdings)
          ..where((t) =>
              t.assetType.isIn(['savings', 'bank_deposit']) &
              t.marketSource.equals('manual') &
              t.costPrice.equals(1) &
              t.latestPrice.equals(1)))
        .get();

    for (final h in legacy) {
      final stmt = _db.update(_db.holdings)..where((t) => t.id.equals(h.id));
      await stmt.write(
        HoldingsCompanion(
          costPrice: Value(h.quantity),
          latestPrice: const Value(1),
        ),
      );
    }

    await _setSetting(_amountBasedMigrated, '${DateTime.now().millisecondsSinceEpoch}');
  }

  Future<void> _migrateGoldSymbol() async {
    final marker = await _getSetting(_goldSymbolMigrated);
    if (marker != null) return;

    final golds = await (_db.select(_db.holdings)
          ..where((t) => t.assetType.equals('gold') & t.symbol.isNull()))
        .get();

    for (final h in golds) {
      final stmt = _db.update(_db.holdings)..where((t) => t.id.equals(h.id));
      await stmt.write(
        const HoldingsCompanion(symbol: Value('AU99.99')),
      );
    }

    await _setSetting(_goldSymbolMigrated, '${DateTime.now().millisecondsSinceEpoch}');
  }

  Future<void> _migrateLiabilityCost() async {
    final marker = await _getSetting(_liabilityCostFixed);
    if (marker != null) return;

    final liabilities = await (_db.select(_db.holdings)
          ..where((t) =>
              t.assetType.equals('liability') & t.costPrice.equals(1).not()))
        .get();

    for (final h in liabilities) {
      final stmt = _db.update(_db.holdings)..where((t) => t.id.equals(h.id));
      await stmt.write(
        const HoldingsCompanion(costPrice: Value(1)),
      );
    }

    await _setSetting(_liabilityCostFixed, '${DateTime.now().millisecondsSinceEpoch}');
  }

  Future<String?> _getSetting(String key) async {
    final row = await (_db.select(_db.settings)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> _setSetting(String key, String value) async {
    await _db.into(_db.settings).insertOnConflictUpdate(
      SettingsCompanion.insert(key: key, value: Value(value)),
    );
  }
}
