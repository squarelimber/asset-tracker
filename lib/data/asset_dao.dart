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

  Future<bool> updateAccount(AccountRow account) async {
    return _db.update(_db.accounts).replace(account);
  }

  Future<int> deleteAccount(int id) async {
    return _db.transaction(() async {
      final holdings =
          await (_db.select(_db.holdings)..where((t) => t.accountId.equals(id))).get();
      for (final h in holdings) {
        await (_db.delete(_db.holdings)..where((t) => t.id.equals(h.id))).go();
        await (_db.delete(_db.transactions)..where((t) => t.holdingId.equals(h.id))).go();
      }
      await (_db.delete(_db.transactions)..where((t) => t.accountId.equals(id))).go();
      return (_db.delete(_db.accounts)..where((t) => t.id.equals(id))).go();
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

  Future<int> deleteHolding(int id) async {
    return _db.transaction(() async {
      await (_db.delete(_db.transactions)..where((t) => t.holdingId.equals(id))).go();
      return (_db.delete(_db.holdings)..where((t) => t.id.equals(id))).go();
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

  Stream<List<TransactionRow>> watchTransactionsByHolding(int holdingId) {
    return (_db.select(_db.transactions)
          ..where((t) => t.holdingId.equals(holdingId))
          ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)]))
        .watch();
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

  Future<int> deleteTransaction(int id) =>
      (_db.delete(_db.transactions)..where((t) => t.id.equals(id))).go();

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

  Future<int> createAlertRule(AlertRulesCompanion entry) =>
      _db.into(_db.alertRules).insert(entry);

  Future<void> updateAlertRule(AlertRuleRow rule) => _db.update(_db.alertRules).replace(rule);

  Future<int> deleteAlertRule(int id) =>
      (_db.delete(_db.alertRules)..where((t) => t.id.equals(id))).go();

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
