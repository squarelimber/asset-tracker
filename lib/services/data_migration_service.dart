import 'package:drift/drift.dart';

import '../core/enums.dart';
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

  /// Transfers recorded before the cost-move fix did not sync the cash
  /// invested amount, so removing them would over-roll the cost. Adds the
  /// cost_moved marker (legacy transfers = 0) and calibrates affected cash
  /// holdings to cost = quantity.
  static const _transferCostMarked = 'transfer_cost_marked_v7';

  /// Runs all pending one-time migrations. Safe to call on every launch.
  Future<void> run() async {
    await _migrateAmountBased();
    await _migrateGoldSymbol();
    await _rebuildHoldingsTable();
    await _migrateLiabilityCost();
    await _migrateTransferCost();
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

  /// Marks legacy transfer rows as not having moved the cash cost and
  /// recalibrates the affected cash holdings (cost = quantity), so both the
  /// display and removal rollbacks become consistent again.
  Future<void> _migrateTransferCost() async {
    final marker = await _getSetting(_transferCostMarked);
    if (marker != null) return;

    // Old databases may not have the column yet (drift reads the new schema,
    // so the column must exist before any typed query runs).
    try {
      await _db.customStatement(
        'ALTER TABLE transactions ADD COLUMN cost_moved INTEGER NOT NULL DEFAULT 1;',
      );
    } catch (_) {
      // Column already present.
    }
    await _db.customStatement(
      "UPDATE transactions SET cost_moved = 0 "
      "WHERE type IN ('transfer_in', 'transfer_out');",
    );

    // Recalibrate cash holdings referenced by transfers. Legacy transfers
    // moved the balance without the cost, so the correct invested amount is
    // cost = quantity + net outflow (money that left via transfer still
    // counts as invested until the transfer is removed). This keeps the
    // displayed rate unchanged while making removal roll back exactly.
    final transferRows = await _db.select(_db.transactions).get();
    final outflow = <int, double>{};
    final inflow = <int, double>{};
    for (final t in transferRows) {
      final isTransfer = t.type == 'transfer_in' || t.type == 'transfer_out';
      if (!isTransfer) continue;
      if (t.cashSourceId != null) {
        outflow[t.cashSourceId!] = (outflow[t.cashSourceId!] ?? 0) + t.amount;
      }
      if (t.cashTargetId != null) {
        inflow[t.cashTargetId!] = (inflow[t.cashTargetId!] ?? 0) + t.amount;
      }
    }
    final affected = {...outflow.keys, ...inflow.keys};
    if (affected.isNotEmpty) {
      final cashHoldings = await (_db.select(_db.holdings)
            ..where((t) => t.id.isIn(affected.toList())))
          .get();
      for (final h in cashHoldings) {
        final type = AssetType.fromStorage(h.assetType);
        if (!type.isAmountBased) continue;
        final netOut = (outflow[h.id] ?? 0) - (inflow[h.id] ?? 0);
        final target = h.quantity + netOut;
        if ((h.costPrice - target).abs() < 0.005) continue;
        final stmt = _db.update(_db.holdings)..where((t) => t.id.equals(h.id));
        await stmt.write(HoldingsCompanion(costPrice: Value(target)));
      }
    }

    await _setSetting(_transferCostMarked, '${DateTime.now().millisecondsSinceEpoch}');
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
