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

  /// Runs all pending one-time migrations. Safe to call on every launch.
  Future<void> run() async {
    await _migrateAmountBased();
    await _migrateGoldSymbol();
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
