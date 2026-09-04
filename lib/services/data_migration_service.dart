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

  /// 512480 (半导体设备ETF) did a 1:2 unit split on 2026-07-03: price
  /// 2.70 -> 1.33, shares x2. Holdings recorded before the split still use
  /// the old share count, which understates the market value by ~50%.
  /// Fix quantity x2 and costPrice /2 once.
  static const _etfSplit512480 = 'etf_split_512480_v8';

  /// Rollback for v8: the user's 512480 holding was already recorded with
  /// post-split values, so the v8 x2 fix doubled it incorrectly. Restore
  /// the original numbers (detected by the doubled-quantity signature).
  static const _etfSplit512480Rollback = 'etf_split_512480_rollback_v9';

  /// Adds the cost_fx_rate column (purchase-time exchange rate for
  /// foreign-currency cost basis) and backfills the known USD holding
  /// (汇利日盈6号A, bought at 6.95).
  static const _costFxRateAdded = 'cost_fx_rate_v10';

  /// Adds the liabilities column to snapshots so the earning view can
  /// exclude principal repayments/borrowing from the return.
  static const _snapshotLiabilitiesAdded = 'snapshot_liabilities_v11';

  /// Repairs fresh installs made on v0.6.0–v0.6.4, where the (then
  /// 14-column) holdings rebuild dropped risk_level and nothing re-added it,
  /// so any write with an explicit risk level failed with "no such column".
  static const _riskLevelAdded = 'risk_level_v12';

  /// Runs all pending one-time migrations. Safe to call on every launch.
  ///
  /// [archived] is repaired first: it is the only non-nullable column whose
  /// absence breaks every typed holdings read, so it must exist before any
  /// other migration selects from the table.
  Future<void> run() async {
    await _migrateArchivedColumn();
    await _migrateAmountBased();
    await _migrateGoldSymbol();
    await _rebuildHoldingsTable();
    await _migrateRiskLevelColumn();
    await _migrateLiabilityCost();
    await _migrateTransferCost();
    await _migrateEtfSplit512480();
    await _rollbackEtfSplit512480();
    await _migrateCostFxRate();
    await _migrateSnapshotLiabilities();
  }

  /// SQLite cannot drop a UNIQUE constraint without rebuilding the table.
  /// Recreate `holdings` with the full drift schema (17 columns) but without
  /// UNIQUE(symbol) so the same market code can exist across multiple
  /// holdings/accounts.
  ///
  /// cost_fx_rate, risk_level and archived may be absent from the old table
  /// when this runs on an upgrade (they arrive with later migrations), so
  /// the copy falls back to NULL / 0 for missing columns.
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
        cost_fx_rate REAL NULL,
        purchase_date INTEGER NULL,
        risk_level TEXT NULL,
        note TEXT NULL,
        archived INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
        updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER))
      );
    ''');
    final oldColumns = await _columnNames('holdings_tmp');
    final costFxSelect =
        oldColumns.contains('cost_fx_rate') ? 'cost_fx_rate' : 'NULL AS cost_fx_rate';
    final riskSelect =
        oldColumns.contains('risk_level') ? 'risk_level' : 'NULL AS risk_level';
    final archivedSelect =
        oldColumns.contains('archived') ? 'archived' : '0 AS archived';
    await _db.customStatement('''
      INSERT INTO holdings (id, account_id, name, asset_type, market_source, symbol,
                            quantity, cost_price, latest_price, currency, cost_fx_rate,
                            purchase_date, risk_level, note, archived,
                            created_at, updated_at)
      SELECT id, account_id, name, asset_type, market_source, symbol,
             quantity, cost_price, latest_price, currency, $costFxSelect,
             purchase_date, $riskSelect, note, $archivedSelect,
             created_at, updated_at
      FROM holdings_tmp;
    ''');
    await _db.customStatement('DROP TABLE holdings_tmp;');

    await _setSetting(_holdingsRebuilt, '${DateTime.now().millisecondsSinceEpoch}');
  }

  /// Re-adds risk_level to databases left broken by the old 14-column
  /// rebuild (fresh installs on v0.6.0–v0.6.4). No-op when the column
  /// already exists.
  Future<void> _migrateRiskLevelColumn() async {
    final marker = await _getSetting(_riskLevelAdded);
    if (marker != null) return;

    try {
      await _db.customStatement('ALTER TABLE holdings ADD COLUMN risk_level TEXT NULL;');
    } catch (_) {
      // Column already present.
    }

    await _setSetting(_riskLevelAdded, '${DateTime.now().millisecondsSinceEpoch}');
  }

  Future<Set<String>> _columnNames(String table) async {
    final rows = await _db.customSelect('PRAGMA table_info($table)').get();
    return rows.map((row) => row.read<String>('name')).toSet();
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

  /// One-time fix for the 512480 1:2 unit split on 2026-07-03.
  Future<void> _migrateEtfSplit512480() async {
    final marker = await _getSetting(_etfSplit512480);
    if (marker != null) return;

    final rows = await (_db.select(_db.holdings)
          ..where((t) => t.symbol.equals('sh512480')))
        .get();
    for (final h in rows) {
      if (h.quantity <= 0) continue;
      final stmt = _db.update(_db.holdings)..where((t) => t.id.equals(h.id));
      await stmt.write(
        HoldingsCompanion(
          quantity: Value(h.quantity * 2),
          costPrice: Value(h.costPrice / 2),
        ),
      );
    }

    await _setSetting(_etfSplit512480, '${DateTime.now().millisecondsSinceEpoch}');
    // The holdings changed; force a snapshot rebuild on the next visit so
    // the net worth history reflects the split correctly.
    if (rows.isNotEmpty) {
      await _db.into(_db.settings).insertOnConflictUpdate(
        SettingsCompanion.insert(key: 'history_sync_dirty', value: const Value('1')),
      );
    }
  }

  /// Undoes [v8][_migrateEtfSplit512480] for holdings that were already
  /// recorded post-split: the doubled-quantity signature (quantity above
  /// 150k for this ETF) identifies the rows the v8 migration touched.
  Future<void> _rollbackEtfSplit512480() async {
    final marker = await _getSetting(_etfSplit512480Rollback);
    if (marker != null) return;

    final rows = await (_db.select(_db.holdings)
          ..where((t) =>
              t.symbol.equals('sh512480') & t.quantity.isBiggerThanValue(150000)))
        .get();
    for (final h in rows) {
      final stmt = _db.update(_db.holdings)..where((t) => t.id.equals(h.id));
      await stmt.write(
        HoldingsCompanion(
          quantity: Value(h.quantity / 2),
          costPrice: Value(h.costPrice * 2),
        ),
      );
    }

    await _setSetting(
      _etfSplit512480Rollback,
      '${DateTime.now().millisecondsSinceEpoch}',
    );
    if (rows.isNotEmpty) {
      await _db.into(_db.settings).insertOnConflictUpdate(
        SettingsCompanion.insert(key: 'history_sync_dirty', value: const Value('1')),
      );
    }
  }

  /// Adds the cost_fx_rate column and backfills the known USD holding's
  /// purchase rate (6.95 for 汇利日盈6号A), then marks history dirty so the
  /// snapshots rebuild with the correct FX conversion.
  Future<void> _migrateCostFxRate() async {
    final marker = await _getSetting(_costFxRateAdded);
    if (marker != null) return;

    try {
      await _db.customStatement(
        'ALTER TABLE holdings ADD COLUMN cost_fx_rate REAL NULL;',
      );
    } catch (_) {
      // Column already present.
    }
    // 汇利日盈6号A (Y05A9W10006A) was bought when USD/CNY was 6.95.
    final stmt = _db.update(_db.holdings)
      ..where((t) => t.symbol.equals('Y05A9W10006A'));
    await stmt.write(
      const HoldingsCompanion(costFxRate: Value(6.95)),
    );

    await _setSetting(_costFxRateAdded, '${DateTime.now().millisecondsSinceEpoch}');
    await _db.into(_db.settings).insertOnConflictUpdate(
      SettingsCompanion.insert(key: 'history_sync_dirty', value: const Value('1')),
    );
  }

  /// Adds the snapshots.liabilities column and marks history dirty so the
  /// rebuild stores the per-day liability amounts.
  Future<void> _migrateSnapshotLiabilities() async {
    final marker = await _getSetting(_snapshotLiabilitiesAdded);
    if (marker != null) return;

    try {
      await _db.customStatement(
        'ALTER TABLE snapshots ADD COLUMN liabilities REAL NOT NULL DEFAULT 0;',
      );
    } catch (_) {
      // Column already present.
    }

    await _setSetting(
      _snapshotLiabilitiesAdded,
      '${DateTime.now().millisecondsSinceEpoch}',
    );
    await _db.into(_db.settings).insertOnConflictUpdate(
      SettingsCompanion.insert(key: 'history_sync_dirty', value: const Value('1')),
    );
  }

  /// Re-adds archived to databases whose holdings table predates the v8
  /// schema. No shipped app version drops the column, but the rebuild path
  /// must never leave a typed read without it, so this is a defensive
  /// no-op-when-present repair (no marker: a marker set while the column is
  /// missing would freeze the broken state forever).
  Future<void> _migrateArchivedColumn() async {
    try {
      await _db.customStatement(
        'ALTER TABLE holdings ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;',
      );
    } catch (_) {
      // Column already present.
    }
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
