import 'package:drift/drift.dart';

import 'database.dart';

/// Data access layer for accounts, holdings, transactions and snapshots.
class AssetDao {
  AssetDao(this._db);

  final AppDatabase _db;

  // ---------------------------------------------------------------------------
  // Accounts
  // ---------------------------------------------------------------------------

  Stream<List<AccountRow>> watchAccounts() {
    return (_db.select(_db.accounts)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).watch();
  }

  Future<AccountRow?> getAccount(int id) {
    return (_db.select(_db.accounts)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<int> createAccount(AccountsCompanion entry) => _db.into(_db.accounts).insert(entry);

  Future<int> updateAccount(AccountRow account, {DateTime? now}) async {
    final stmt = _db.update(_db.accounts)..where((t) => t.id.equals(account.id));
    return stmt.write(
      AccountsCompanion(
        name: Value(account.name),
        type: Value(account.type),
        currency: Value(account.currency),
        note: Value(account.note),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  Future<int> deleteAccount(int id) async {
    return _db.transaction(() async {
      final holdings =
          await (_db.select(_db.holdings)..where((t) => t.accountId.equals(id))).get();
      final cascadeTransactions = await (_db.select(_db.transactions)
            ..where((t) => t.accountId.equals(id)))
          .get();
      for (final h in holdings) {
        final hTransactions = await (_db.select(_db.transactions)
              ..where((t) => t.holdingId.equals(h.id)))
            .get();
        cascadeTransactions.addAll(hTransactions);
        await (_db.delete(_db.holdings)..where((t) => t.id.equals(h.id))).go();
        await upsertTombstone('holdings', '${h.id}');
      }
      for (final t in cascadeTransactions) {
        await upsertTombstone('transactions', '${t.id}');
      }
      await (_db.delete(_db.transactions)..where((t) => t.accountId.equals(id))).go();
      await (_db.delete(_db.accounts)..where((t) => t.id.equals(id))).go();
      await upsertTombstone('accounts', '$id');
      return id;
    });
  }

  // ---------------------------------------------------------------------------
  // Holdings
  // ---------------------------------------------------------------------------

  Stream<List<HoldingRow>> watchHoldings() {
    return _db.select(_db.holdings).watch();
  }

  Stream<List<HoldingRow>> watchHoldingsByAccount(int accountId) {
    return (_db.select(_db.holdings)..where((t) => t.accountId.equals(accountId))).watch();
  }

  Future<List<HoldingRow>> getHoldings() => _db.select(_db.holdings).get();

  Future<HoldingRow?> getHolding(int id) {
    return (_db.select(_db.holdings)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<HoldingRow?> getHoldingBySymbol(String symbol) {
    return (_db.select(_db.holdings)
          ..where((t) => t.symbol.equals(symbol)))
        .getSingleOrNull();
  }

  Future<int> createHolding(HoldingsCompanion entry) => _db.into(_db.holdings).insert(entry);

  Future<void> updateHolding(HoldingRow holding, {DateTime? now}) async {
    final stmt = _db.update(_db.holdings)..where((t) => t.id.equals(holding.id));
    await stmt.write(
      HoldingsCompanion(
        name: Value(holding.name),
        accountId: Value(holding.accountId),
        assetType: Value(holding.assetType),
        marketSource: Value(holding.marketSource),
        symbol: Value(holding.symbol),
        quantity: Value(holding.quantity),
        costPrice: Value(holding.costPrice),
        latestPrice: Value(holding.latestPrice),
        currency: Value(holding.currency),
        purchaseDate: Value(holding.purchaseDate),
        note: Value(holding.note),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  /// Deletes a holding and every transaction referencing it — as the direct
  /// subject (holdingId) or as a transfer counterparty (cashSourceId /
  /// cashTargetId), so no orphan flows are left behind.
  Future<int> deleteHolding(int id) async {
    return _db.transaction(() async {
      final deleted = <TransactionRow>[
        ...await (_db.select(_db.transactions)..where((t) => t.holdingId.equals(id))).get(),
        ...await (_db.select(_db.transactions)..where((t) => t.cashSourceId.equals(id))).get(),
        ...await (_db.select(_db.transactions)..where((t) => t.cashTargetId.equals(id))).get(),
      ];
      await (_db.delete(_db.transactions)..where((t) => t.holdingId.equals(id))).go();
      await (_db.delete(_db.transactions)..where((t) => t.cashSourceId.equals(id))).go();
      await (_db.delete(_db.transactions)..where((t) => t.cashTargetId.equals(id))).go();
      for (final t in deleted) {
        await upsertTombstone('transactions', '${t.id}');
      }
      await (_db.delete(_db.holdings)..where((t) => t.id.equals(id))).go();
      await upsertTombstone('holdings', '$id');
      return id;
    });
  }

  Future<void> updateHoldingPrice(int id, double price) async {
    final stmt = _db.update(_db.holdings)..where((t) => t.id.equals(id));
    await stmt.write(
      HoldingsCompanion(
        latestPrice: Value(price),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Transactions
  // ---------------------------------------------------------------------------

  Stream<List<TransactionRow>> watchTransactions() {
    return (_db.select(_db.transactions)
          ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)]))
        .watch();
  }

  Stream<List<TransactionRow>> watchTransactionsByAccount(int accountId) {
    return (_db.select(_db.transactions)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)]))
        .watch();
  }

  /// Transactions where the holding is the subject (holdingId) or a transfer
  /// counterparty (cashSourceId / cashTargetId), so transfers and loan
  /// repayments show up in the holding's detail sheet too.
  Stream<List<TransactionRow>> watchTransactionsByHolding(int holdingId) {
    return (_db.select(_db.transactions)
          ..where((t) =>
              t.holdingId.equals(holdingId) |
              t.cashSourceId.equals(holdingId) |
              t.cashTargetId.equals(holdingId))
          ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)]))
        .watch();
  }

  /// One-shot variant of [watchTransactionsByHolding].
  Future<List<TransactionRow>> getTransactionsForHolding(int holdingId) {
    return (_db.select(_db.transactions)
          ..where((t) =>
              t.holdingId.equals(holdingId) |
              t.cashSourceId.equals(holdingId) |
              t.cashTargetId.equals(holdingId)))
        .get();
  }

  Future<List<TransactionRow>> getTransactions() => _db.select(_db.transactions).get();

  Future<int> createTransaction(TransactionsCompanion entry) =>
      _db.into(_db.transactions).insert(entry);

  Future<TransactionRow?> getTransaction(int id) {
    return (_db.select(_db.transactions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Whether another transaction exists for the same holding with a newer
  /// entry order (larger id) — used for chronological reversal checks.
  Future<bool> hasNewerTransaction(int holdingId, int id) async {
    final rows = await (_db.select(_db.transactions)
          ..where((t) => t.holdingId.equals(holdingId) & t.id.isBiggerThanValue(id))
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  Future<int> deleteTransaction(int id) async {
    return _db.transaction(() async {
      await (_db.delete(_db.transactions)..where((t) => t.id.equals(id))).go();
      await upsertTombstone('transactions', '$id');
      return id;
    });
  }

  /// Writes a transaction row as-is (used by sync to apply merged rows
  /// without re-running the buy/sell/transfer linkage logic).
  Future<void> updateTransaction(TransactionRow t, {DateTime? now}) async {
    final stmt = _db.update(_db.transactions)..where((c) => c.id.equals(t.id));
    await stmt.write(
      TransactionsCompanion(
        accountId: Value(t.accountId),
        holdingId: Value(t.holdingId),
        cashSourceId: Value(t.cashSourceId),
        cashTargetId: Value(t.cashTargetId),
        type: Value(t.type),
        quantity: Value(t.quantity),
        price: Value(t.price),
        amount: Value(t.amount),
        currency: Value(t.currency),
        occurredAt: Value(t.occurredAt),
        note: Value(t.note),
        costMoved: Value(t.costMoved),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Price cache
  // ---------------------------------------------------------------------------

  Future<PriceCacheRow?> getCachedPrice(String symbol) {
    return (_db.select(_db.priceCache)..where((t) => t.symbol.equals(symbol)))
        .getSingleOrNull();
  }

  Future<Map<String, PriceCacheRow>> getCachedPrices(List<String> symbols) async {
    if (symbols.isEmpty) return {};
    final rows = await (_db.select(_db.priceCache)
          ..where((t) => t.symbol.isIn(symbols)))
        .get();
    return {for (final r in rows) r.symbol: r};
  }

  Future<void> upsertPriceCache(PriceCacheRow row) {
    return _db.into(_db.priceCache).insertOnConflictUpdate(row);
  }

  // ---------------------------------------------------------------------------
  // Snapshots
  // ---------------------------------------------------------------------------

  Future<SnapshotRow?> getSnapshot(String date, String currency) {
    return (_db.select(_db.snapshots)
          ..where((t) => t.date.equals(date) & t.currency.equals(currency)))
        .getSingleOrNull();
  }

  Stream<List<SnapshotRow>> watchSnapshots({String? currency}) {
    final query = _db.select(_db.snapshots)
      ..orderBy([(t) => OrderingTerm.asc(t.date)]);
    if (currency != null) {
      query.where((t) => t.currency.equals(currency));
    }
    return query.watch();
  }

  Future<void> upsertSnapshot(SnapshotsCompanion entry) {
    return _db.into(_db.snapshots).insertOnConflictUpdate(entry);
  }

  /// Deletes snapshots strictly before [date] (yyyy-MM-dd).
  Future<void> deleteSnapshotsBefore(String date) {
    return (_db.delete(_db.snapshots)..where((t) => t.date.isSmallerThanValue(date))).go();
  }

  /// Deletes one snapshot row by its composite key.
  Future<void> deleteSnapshot(String date, String currency) {
    return (_db.delete(_db.snapshots)
          ..where((t) => t.date.equals(date) & t.currency.equals(currency)))
        .go();
  }

  /// Bulk-inserts snapshots in one transaction (much faster than per-row).
  Future<void> batchInsertSnapshots(List<SnapshotRow> rows, {bool orReplace = true}) async {
    await _db.batch((b) {
      for (final row in rows) {
        b.insert(_db.snapshots, row,
            mode: orReplace ? InsertMode.replace : InsertMode.insert);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Settings (key-value app state)
  // ---------------------------------------------------------------------------

  Future<String?> getSetting(String key) async {
    final row = await (_db.select(_db.settings)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) {
    return _db.into(_db.settings).insertOnConflictUpdate(
      SettingsCompanion.insert(key: key, value: Value(value)),
    );
  }

  // ---------------------------------------------------------------------------
  // Alert rules
  // ---------------------------------------------------------------------------

  Stream<List<AlertRuleRow>> watchAlertRules() {
    return (_db.select(_db.alertRules)..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch();
  }

  Future<List<AlertRuleRow>> getAlertRules() => _db.select(_db.alertRules).get();

  Future<AlertRuleRow?> getAlertRule(int id) {
    return (_db.select(_db.alertRules)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<int> createAlertRule(AlertRulesCompanion entry) =>
      _db.into(_db.alertRules).insert(entry);

  Future<void> updateAlertRule(AlertRuleRow rule, {DateTime? now}) async {
    final stmt = _db.update(_db.alertRules)..where((t) => t.id.equals(rule.id));
    await stmt.write(
      AlertRulesCompanion(
        type: Value(rule.type),
        name: Value(rule.name),
        params: Value(rule.params),
        enabled: Value(rule.enabled),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  Future<int> deleteAlertRule(int id) async {
    return _db.transaction(() async {
      await (_db.delete(_db.alertRules)..where((t) => t.id.equals(id))).go();
      await upsertTombstone('alertRules', '$id');
      return id;
    });
  }

  // ---------------------------------------------------------------------------
  // Alert events
  // ---------------------------------------------------------------------------

  Future<AlertEventRow?> getRecentAlertEvent(int ruleId, DateTime since) {
    return (_db.select(_db.alertEvents)
          ..where((t) => t.ruleId.equals(ruleId) & t.triggeredAt.isBiggerOrEqualValue(since))
          ..limit(1))
        .getSingleOrNull();
  }

  Stream<List<AlertEventRow>> watchRecentAlertEvents({int limit = 20}) {
    return (_db.select(_db.alertEvents)
          ..orderBy([(t) => OrderingTerm.desc(t.triggeredAt)])
          ..limit(limit))
        .watch();
  }

  Future<int> createAlertEvent(AlertEventsCompanion entry) =>
      _db.into(_db.alertEvents).insert(entry);

  // ---------------------------------------------------------------------------
  // Sync tombstones
  // ---------------------------------------------------------------------------

  Stream<List<SyncTombstoneRow>> watchTombstones() =>
      _db.select(_db.syncTombstones).watch();

  Future<List<SyncTombstoneRow>> getTombstones() =>
      _db.select(_db.syncTombstones).get();

  Future<void> upsertTombstone(
    String table,
    String rowKey, {
    DateTime? deletedAt,
  }) =>
      _db.into(_db.syncTombstones).insertOnConflictUpdate(
            SyncTombstonesCompanion.insert(
              table: table,
              rowKey: rowKey,
              deletedAt: Value(deletedAt ?? DateTime.now()),
            ),
          );

  Future<int> removeTombstone(String table, String rowKey) =>
      (_db.delete(_db.syncTombstones)
            ..where((t) => t.table.equals(table) & t.rowKey.equals(rowKey)))
          .go();

  /// Deletes a tombstone row entirely (used after a tombstone is pushed to
  /// the server so it does not re-apply locally).
  Future<void> deleteTombstoneRow(SyncTombstoneRow row) =>
      _db.delete(_db.syncTombstones).delete(row);

  Future<void> deleteAllTombstones() => _db.delete(_db.syncTombstones).go();

  // ---------------------------------------------------------------------------
  // Bulk access for backup/restore
  // ---------------------------------------------------------------------------

  Future<List<AccountRow>> getAccounts() => _db.select(_db.accounts).get();
  Future<List<SnapshotRow>> getSnapshots() => _db.select(_db.snapshots).get();

  Future<void> deleteAllTransactions() => _db.delete(_db.transactions).go();
  Future<void> deleteAllHoldings() => _db.delete(_db.holdings).go();
  Future<void> deleteAllAccounts() => _db.delete(_db.accounts).go();
  Future<void> deleteAllSnapshots() => _db.delete(_db.snapshots).go();
  Future<void> deleteAllAlertRules() => _db.delete(_db.alertRules).go();

  /// Runs [action] inside a transaction.
  Future<T> transaction<T>(Future<T> Function() action) => _db.transaction(action);
}
