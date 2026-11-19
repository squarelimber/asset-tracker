import 'dart:math';

import 'package:drift/drift.dart';

import '../core/enums.dart';
import '../core/formats.dart';
import '../core/history_sync.dart';
import '../core/nav_history.dart';
import '../core/symbols.dart';
import '../domain/transaction_identity.dart';
import 'database.dart';

/// Data access layer for accounts, holdings, transactions and snapshots.
class AssetDao {
  AssetDao(this._db);

  final AppDatabase _db;
  static final _random = Random.secure();
  static int _lastRecordedAt = 0;

  /// Explicit IDs prevent offline devices from allocating the same local
  /// sequence number. Keep them exact in JavaScript and JSON as well as SQLite.
  static int newSyncId() {
    const block = 67108864; // 2^26
    const first = 4503599627370496; // 2^52
    return first + _random.nextInt(block) * block + _random.nextInt(block);
  }

  // ---------------------------------------------------------------------------
  // Accounts
  // ---------------------------------------------------------------------------

  Stream<List<AccountRow>> watchAccounts() {
    return (_db.select(
      _db.accounts,
    )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).watch();
  }

  Future<AccountRow?> getAccount(int id) {
    return (_db.select(
      _db.accounts,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<int> createAccount(AccountsCompanion entry) => _db.into(_db.accounts)
      .insert(entry.id.present ? entry : entry.copyWith(id: Value(newSyncId())));

  Future<int> updateAccount(AccountRow account, {DateTime? now}) async {
    final stmt = _db.update(_db.accounts)
      ..where((t) => t.id.equals(account.id));
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

  /// Updates the editable account fields without overwriting values that may
  /// have changed while the edit dialog was open.
  Future<int> updateAccountDetails(
    int id, {
    required String name,
    required String? note,
  }) {
    return (_db.update(_db.accounts)..where((t) => t.id.equals(id))).write(
      AccountsCompanion(
        name: Value(name),
        note: Value(note),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<int> deleteAccount(int id) async {
    return _db.transaction(() async {
      final holdings = await (_db.select(
        _db.holdings,
      )..where((t) => t.accountId.equals(id))).get();
      final localTransactions = await (_db.select(
        _db.transactions,
      )..where((t) => t.accountId.equals(id))).get();
      final related = await _transactionsAffectedByHoldingDeletion(
        holdings.map((h) => h.id).toList(),
        initial: localTransactions,
      );
      final holdingIds = holdings.map((h) => h.id).toSet();
      if (related.values.any((row) =>
          row.accountId != id ||
          [row.holdingId, row.cashSourceId, row.cashTargetId]
              .whereType<int>()
              .any((ref) => !holdingIds.contains(ref)))) {
        throw ArgumentError('此账户仍有关联的跨账户流水，请先撤销关联流水，或归档持仓');
      }
      for (final t in related.values) {
        await deleteTransaction(t.id);
      }
      for (final h in holdings) {
        await deleteHoldingRowOnly(h.id);
      }
      await deleteAccountRowOnly(id);
      await setSetting(historySyncDirtyKey, historyDirtySet);
      return id;
    });
  }

  Future<void> deleteAccountRowOnly(int id) async {
    await (_db.delete(_db.accounts)..where((t) => t.id.equals(id))).go();
    await upsertTombstone('accounts', '$id');
  }

  /// Moves a legacy row out of a colliding local sequence slot. References
  /// are moved in the same SQLite transaction as the subsequent merge.
  Future<void> rekeySyncAccount(int oldId, int newId) async {
    await (_db.update(_db.accounts)..where((t) => t.id.equals(oldId)))
        .write(AccountsCompanion(id: Value(newId)));
    await (_db.update(_db.holdings)..where((t) => t.accountId.equals(oldId)))
        .write(HoldingsCompanion(accountId: Value(newId)));
    await (_db.update(_db.transactions)..where((t) => t.accountId.equals(oldId)))
        .write(TransactionsCompanion(accountId: Value(newId)));
  }

  Future<void> rekeySyncHolding(int oldId, int newId) async {
    await (_db.update(_db.holdings)..where((t) => t.id.equals(oldId)))
        .write(HoldingsCompanion(id: Value(newId)));
    await (_db.update(_db.transactions)..where((t) => t.holdingId.equals(oldId)))
        .write(TransactionsCompanion(holdingId: Value(newId)));
    await (_db.update(_db.transactions)..where((t) => t.cashSourceId.equals(oldId)))
        .write(TransactionsCompanion(cashSourceId: Value(newId)));
    await (_db.update(_db.transactions)..where((t) => t.cashTargetId.equals(oldId)))
        .write(TransactionsCompanion(cashTargetId: Value(newId)));
  }

  Future<void> rekeySyncTransaction(int oldId, int newId) async {
    final row = await getTransaction(oldId);
    if (row == null) return;
    await (_db.update(_db.transactions)..where((t) => t.id.equals(oldId)))
        .write(TransactionsCompanion(
          id: Value(newId),
          recordedAtMicros: Value(
            row.recordedAtMicros ?? legacyTransactionEntryOrder(oldId),
          ),
        ));
  }

  Future<void> rekeySyncAlertRule(int oldId, int newId) async {
    await (_db.update(_db.alertRules)..where((t) => t.id.equals(oldId)))
        .write(AlertRulesCompanion(id: Value(newId)));
    await (_db.update(_db.alertEvents)..where((t) => t.ruleId.equals(oldId)))
        .write(AlertEventsCompanion(ruleId: Value(newId)));
  }

  // ---------------------------------------------------------------------------
  // Holdings
  // ---------------------------------------------------------------------------

  Stream<List<HoldingRow>> watchHoldings() {
    return (_db.select(_db.holdings)..orderBy([
      (t) => OrderingTerm.asc(t.createdAt),
      (t) => OrderingTerm.asc(t.id),
    ])).watch();
  }

  Stream<List<HoldingRow>> watchHoldingsByAccount(int accountId) {
    return (_db.select(
      _db.holdings,
    )..where((t) => t.accountId.equals(accountId))
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)])).watch();
  }

  Future<List<HoldingRow>> getHoldings() => (_db.select(_db.holdings)
    ..orderBy([(t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)])).get();

  Future<HoldingRow?> getHolding(int id) {
    return (_db.select(
      _db.holdings,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<HoldingRow?> getHoldingBySymbol(String symbol) {
    return (_db.select(
      _db.holdings,
    )..where((t) => t.symbol.equals(symbol))).getSingleOrNull();
  }

  Future<int> createHolding(HoldingsCompanion entry) => _db.into(_db.holdings)
      .insert(entry.id.present ? entry : entry.copyWith(id: Value(newSyncId())));

  Future<void> updateHolding(HoldingRow holding, {DateTime? now}) async {
    final stmt = _db.update(_db.holdings)
      ..where((t) => t.id.equals(holding.id));
    await stmt.write(
      HoldingsCompanion(
        name: Value(holding.name),
        accountId: Value(holding.accountId),
        assetType: Value(holding.assetType),
        marketSource: Value(holding.marketSource),
        symbol: Value(holding.symbol),
        quantity: Value(holding.quantity),
        costPrice: Value(holding.costPrice),
        costRecorded: Value(holding.costRecorded),
        latestPrice: Value(holding.latestPrice),
        manualNavHistory: Value(holding.manualNavHistory),
        costFxRate: Value(holding.costFxRate),
        currency: Value(holding.currency),
        purchaseDate: Value(holding.purchaseDate),
        riskLevel: Value(holding.riskLevel),
        categoryOverride: Value(holding.categoryOverride),
        note: Value(holding.note),
        archived: Value(holding.archived),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  /// Archives (or un-archives) a holding. Archived rows stay in the database
  /// — including their transactions and earnings-calendar history — but are
  /// hidden from the default holdings views.
  Future<void> setArchived(int id, bool archived, {DateTime? now}) async {
    final stmt = _db.update(_db.holdings)..where((t) => t.id.equals(id));
    await stmt.write(
      HoldingsCompanion(
        archived: Value(archived),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  /// Deletes a holding and all flows demonstrably linked to it.
  Future<int> deleteHolding(int id) async {
    return _db.transaction(() async {
      final related = await _transactionsAffectedByHoldingDeletion([id]);
      for (final t in related.values) {
        await deleteTransaction(t.id);
      }
      await deleteHoldingRowOnly(id);
      await setSetting(historySyncDirtyKey, historyDirtySet);
      return id;
    });
  }

  Future<Map<int, TransactionRow>> _transactionsAffectedByHoldingDeletion(
    List<int> holdingIds, {
    List<TransactionRow> initial = const [],
  }) async {
    final related = {for (final row in initial) row.id: row};
    if (holdingIds.isNotEmpty) {
      final rows = await (_db.select(_db.transactions)..where(
        (t) => t.holdingId.isIn(holdingIds) |
            t.cashSourceId.isIn(holdingIds) |
            t.cashTargetId.isIn(holdingIds),
      )).get();
      related.addEntries(rows.map((row) => MapEntry(row.id, row)));
    }
    for (final row in related.values.toList()) {
      final partner = await getRedemptionPartner(row);
      if (partner != null) related[partner.id] = partner;
    }
    return related;
  }

  /// Deletes a holding row and writes its tombstone WITHOUT touching its
  /// transactions. Used by sync dedup: the merge has already re-pointed the
  /// loser holding's flows to the surviving holding (same flow ids, new
  /// holding refs), so cascading here would tombstone those flows and the
  /// upsert guard would drop their re-insertion — losing the history.
  Future<void> deleteHoldingRowOnly(int id) async {
    return _db.transaction(() async {
      await (_db.delete(_db.holdings)..where((t) => t.id.equals(id))).go();
      await upsertTombstone('holdings', '$id');
    });
  }

  /// Writes a refreshed market price. Deliberately does NOT bump
  /// `updatedAt`: prices are volatile cache data, and bumping the edit
  /// timestamp on every refresh would make each refresh look like a user
  /// edit (spurious sync conflicts and needless history rebuilds).
  Future<void> updateHoldingPrice(int id, double price) async {
    final stmt = _db.update(_db.holdings)..where((t) => t.id.equals(id));
    await stmt.write(HoldingsCompanion(latestPrice: Value(price)));
  }

  /// Keeps actual bank NAV observations separate from ledger transactions.
  /// A backdated point changes the chart without repricing today's holding.
  Future<void> recordManualNav(int id, DateTime date, double price, {DateTime? now}) async {
    final recordedAt = now ?? DateTime.now();
    final today = todayKey(recordedAt);
    final day = todayKey(date);
    if (!price.isFinite || price <= 0 || day.compareTo(today) > 0) {
      throw ArgumentError('净值须大于 0，日期须为今天或更早');
    }
    await transaction(() async {
      final holding = await getHolding(id);
      if (holding == null || !hasManualNav(holding)) {
        throw ArgumentError('该持仓不支持手工净值记录');
      }
      final values = decodeNavHistory(holding.manualNavHistory)..[day] = price;
      await (_db.update(_db.holdings)..where((t) => t.id.equals(id))).write(
        HoldingsCompanion(
          manualNavHistory: Value(encodeNavHistory(values)),
          latestPrice: day == today ? Value(price) : const Value.absent(),
          updatedAt: Value(recordedAt),
        ),
      );
      await setSetting(historyFullRebuildKey, '1');
      await setSetting(historySyncDirtyKey, historyDirtySet);
    });
  }

  // ---------------------------------------------------------------------------
  // Transactions
  // ---------------------------------------------------------------------------

  Stream<List<TransactionRow>> watchTransactions() {
    return (_db.select(
      _db.transactions,
    )..orderBy([(t) => OrderingTerm.desc(t.occurredAt)])).watch();
  }

  Stream<List<TransactionRow>> watchTransactionsByAccount(int accountId) {
    final transactions = _db.transactions;
    final source = _db.alias(_db.holdings, 'source_holding');
    final target = _db.alias(_db.holdings, 'target_holding');
    final query = _db.select(transactions).join([
      leftOuterJoin(source, source.id.equalsExp(transactions.cashSourceId)),
      leftOuterJoin(target, target.id.equalsExp(transactions.cashTargetId)),
    ]);
    query.where(
      transactions.accountId.equals(accountId) |
          (transactions.type.isIn([
                TransactionType.transferIn.storageName,
                TransactionType.transferOut.storageName,
              ]) &
              (source.accountId.equals(accountId) |
                  target.accountId.equals(accountId))),
    );
    query.orderBy([OrderingTerm.desc(transactions.occurredAt)]);
    return query.watch().map(
          (rows) => rows.map((row) => row.readTable(transactions)).toList(),
        );
  }

  /// Transactions where the holding is the subject (holdingId) or a transfer
  /// counterparty (cashSourceId / cashTargetId), so transfers and loan
  /// repayments show up in the holding's detail sheet too.
  Stream<List<TransactionRow>> watchTransactionsByHolding(int holdingId) {
    return (_db.select(_db.transactions)
          ..where(
            (t) =>
                t.holdingId.equals(holdingId) |
                t.cashSourceId.equals(holdingId) |
                t.cashTargetId.equals(holdingId),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)]))
        .watch();
  }

  /// One-shot variant of [watchTransactionsByHolding].
  Future<List<TransactionRow>> getTransactionsForHolding(int holdingId) async {
    return (await (_db.select(_db.transactions)..where(
          (t) =>
              t.holdingId.equals(holdingId) |
              t.cashSourceId.equals(holdingId) |
              t.cashTargetId.equals(holdingId),
        )).get())..sort(compareTransactionEntryOrder);
  }

  Future<List<TransactionRow>> getTransactions() async =>
      (await _db.select(_db.transactions).get())..sort(compareTransactionEntryOrder);

  Future<TransactionRow?> getRedemptionPartner(TransactionRow row) async {
    if (!isRedemptionLeg(row)) return null;
    final group = row.redemptionGroup;
    final candidates = await (_db.select(_db.transactions)..where(
      (t) => group != null
          ? t.redemptionGroup.equals(group)
          : t.occurredAt.equals(row.occurredAt) & t.redemptionGroup.isNull(),
    )).get();
    return redemptionPartner(row, candidates);
  }

  Future<List<TransactionRow>> getTransactionsSince(DateTime start) =>
      (_db.select(_db.transactions)
            ..where((t) => t.occurredAt.isBiggerOrEqualValue(start)))
          .get();

  Future<int> createTransaction(TransactionsCompanion entry) {
    if (!entry.id.present) {
      final now = DateTime.now().microsecondsSinceEpoch;
      _lastRecordedAt = max(now, _lastRecordedAt + 1);
      entry = entry.copyWith(
        id: Value(newSyncId()),
        recordedAtMicros: Value(_lastRecordedAt),
        opensHolding: entry.opensHolding.present
            ? entry.opensHolding
            : const Value(false),
      );
    }
    return _db.into(_db.transactions).insert(entry);
  }

  Future<TransactionRow?> getTransaction(int id) {
    return (_db.select(
      _db.transactions,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Whether a position changed after the original mutation was recorded.
  Future<bool> hasNewerTransaction(int holdingId, TransactionRow row) async {
    final rows = await getTransactionsForHolding(holdingId);
    return rows.any((other) =>
        other.holdingId == holdingId &&
        compareTransactionEntryOrder(other, row) > 0);
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
        costMovedAmount: Value(t.costMovedAmount),
        externalSellPrincipal: Value(t.externalSellPrincipal),
        internalMove: Value(t.internalMove),
        redemptionGroup: Value(t.redemptionGroup),
        opensHolding: Value(t.opensHolding),
        recordedAtMicros: Value(t.recordedAtMicros),
        ledgerUpdatedAt: Value(t.ledgerUpdatedAt),
        updatedAt: Value(now ?? DateTime.now()),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Price cache
  // ---------------------------------------------------------------------------

  Future<PriceCacheRow?> getCachedPrice(String symbol) {
    return (_db.select(
      _db.priceCache,
    )..where((t) => t.symbol.equals(symbol))).getSingleOrNull();
  }

  Future<Map<String, PriceCacheRow>> getCachedPrices(
    List<String> symbols,
  ) async {
    if (symbols.isEmpty) return {};
    final rows = await (_db.select(
      _db.priceCache,
    )..where((t) => t.symbol.isIn(symbols))).get();
    return {for (final r in rows) r.symbol: r};
  }

  /// Overwrite the cached quote for the row's symbol.
  ///
  /// Takes a [PriceCacheCompanion] rather than a [PriceCacheRow] so a refresh
  /// can write *explicit* nulls. `insertOnConflictUpdate` merges — a row built
  /// from a data class omits its null columns, so a source that returns a price
  /// but no move (gold with no previous close, a fund with no NAVCHGRT) would
  /// leave the *previous* `change` / `prev_close` in place while still bumping
  /// `fetched_at`. The "written today" guard then passes and the stale move is
  /// read back as today's — worst after the app has been closed for a while,
  /// when the leftover value is days or weeks old. A companion's `Value(null)`
  /// lands as a real NULL, so every refresh fully replaces the row.
  Future<void> upsertPriceCache(PriceCacheCompanion row) {
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

  Future<SnapshotRow?> getLatestSnapshot(String currency) =>
      (_db.select(_db.snapshots)
        ..where((row) => row.currency.equals(currency))
        ..orderBy([(row) => OrderingTerm.desc(row.date)])
        ..limit(1)).getSingleOrNull();

  Stream<List<SnapshotRow>> watchSnapshots({String? currency}) {
    final query = _db.select(_db.snapshots)
      ..orderBy([(t) => OrderingTerm.asc(t.date)]);
    if (currency != null) {
      query.where((t) => t.currency.equals(currency));
    }
    return query.watch();
  }

  Future<void> upsertSnapshot(SnapshotsCompanion entry) {
    // Legacy writers/sync peers must clear a previous explanation rather
    // than attaching old holdings to a new aggregate with the same key.
    return _db
        .into(_db.snapshots)
        .insertOnConflictUpdate(
          entry.copyWith(
            holdingValues: entry.holdingValues.present
                ? entry.holdingValues
                : const Value(null),
            realizedProfit: entry.realizedProfit.present
                ? entry.realizedProfit
                : const Value(null),
          ),
        );
  }

  /// Deletes snapshots strictly before [date] (yyyy-MM-dd), recording a
  /// sync tombstone per removed row so other devices do not resurrect
  /// them from the server snapshot on the next merge.
  ///
  /// [replacedKeys] holds the `date|currency` rows the caller is about to
  /// re-insert in the same transaction (a full rebuild recomputes the whole
  /// window). Those days must NOT be tombstoned: `deletedAt` is stamped with
  /// the clock *as each row is visited* — a 2000-day loop takes tens of
  /// seconds — while the rebuilt rows carry the instant the rebuild began,
  /// which is earlier. The tombstone would then outrank the very row it was
  /// meant to replace and the next merge would delete the whole freshly
  /// rebuilt history (2026-10-09: an auto sync at 15:40 wiped every day but
  /// today from a rebuild that finished at 15:23). Any tombstone already on
  /// record for those keys is obsolete for the same reason, so it is cleared
  /// too — the fix then does not depend on clock ordering at all.
  Future<void> deleteSnapshotsBefore(
    String date, {
    Set<String> replacedKeys = const {},
  }) async {
    final doomed = await (_db.select(
      _db.snapshots,
    )..where((t) => t.date.isSmallerThanValue(date))).get();
    await (_db.delete(
      _db.snapshots,
    )..where((t) => t.date.isSmallerThanValue(date))).go();
    for (final row in doomed) {
      final key = '${row.date}|${row.currency}';
      if (replacedKeys.contains(key)) continue;
      await upsertTombstone('snapshots', key);
    }
    if (replacedKeys.isEmpty) return;
    // Chunked: SQLite caps how many parameters one statement may bind.
    final keys = replacedKeys.toList();
    for (var i = 0; i < keys.length; i += 500) {
      final end = i + 500 < keys.length ? i + 500 : keys.length;
      await (_db.delete(_db.syncTombstones)..where(
            (t) =>
                t.table.equals('snapshots') &
                t.rowKey.isIn(keys.sublist(i, end)),
          ))
          .go();
    }
  }

  /// Deletes one snapshot row by its composite key (with tombstone).
  Future<void> deleteSnapshot(String date, String currency) async {
    await (_db.delete(
      _db.snapshots,
    )..where((t) => t.date.equals(date) & t.currency.equals(currency))).go();
    await upsertTombstone('snapshots', '$date|$currency');
  }

  /// Bulk-inserts snapshots in one transaction (much faster than per-row).
  Future<void> batchInsertSnapshots(
    List<SnapshotRow> rows, {
    bool orReplace = true,
  }) async {
    await _db.batch((b) {
      for (final row in rows) {
        b.insert(
          _db.snapshots,
          row,
          mode: orReplace ? InsertMode.replace : InsertMode.insert,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Settings (key-value app state)
  // ---------------------------------------------------------------------------

  Future<String?> getSetting(String key) async {
    final row = await (_db.select(
      _db.settings,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) {
    return _db
        .into(_db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(key: key, value: Value(value)),
        );
  }

  /// Watches one settings row so providers can react to flag flips (e.g.
  /// a startup auto-sync setting the history dirty flag after the provider
  /// was first computed).
  ///
  /// The `distinct()` is load-bearing, not cosmetic. Drift re-runs the query
  /// and emits on **any** write to the settings table — including writes to
  /// other keys — and Riverpod re-executes a dependent provider for every
  /// emission even when the value is identical. Without the dedupe, a
  /// provider that watches a flag and also writes some *other* setting
  /// re-triggers itself forever. Seen 2026-09-16: the backfill started
  /// recording its last-run anchor, and `historySyncProvider` — which
  /// watches the dirty flag and calls the backfill — span in a loop, so the
  /// app flooded "已回填 1 天历史净值" snackbars and the earnings calendar
  /// reloaded endlessly.
  Stream<String?> watchSetting(String key) =>
      (_db.select(_db.settings)..where((t) => t.key.equals(key)))
          .watchSingleOrNull()
          .map((row) => row?.value)
          .distinct();

  // ---------------------------------------------------------------------------
  // Alert rules
  // ---------------------------------------------------------------------------

  Stream<List<AlertRuleRow>> watchAlertRules() {
    return (_db.select(
      _db.alertRules,
    )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).watch();
  }

  Future<List<AlertRuleRow>> getAlertRules() =>
      _db.select(_db.alertRules).get();

  Future<AlertRuleRow?> getAlertRule(int id) {
    return (_db.select(
      _db.alertRules,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<int> createAlertRule(AlertRulesCompanion entry) => _db.into(_db.alertRules)
      .insert(entry.id.present ? entry : entry.copyWith(id: Value(newSyncId())));

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
          ..where(
            (t) =>
                t.ruleId.equals(ruleId) &
                t.triggeredAt.isBiggerOrEqualValue(since),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<List<AlertEventRow>> getAlertEventsForDay(
      int ruleId, DateTime dayStart, DateTime dayEnd) {
    return (_db.select(_db.alertEvents)
          ..where((t) => t.ruleId.equals(ruleId) &
              t.triggeredAt.isBiggerOrEqualValue(dayStart) &
              t.triggeredAt.isSmallerThanValue(dayEnd)))
        .get();
  }

  Stream<List<AlertEventRow>> watchRecentAlertEvents({int limit = 20}) {
    return (_db.select(_db.alertEvents)
          ..orderBy([(t) => OrderingTerm.desc(t.triggeredAt)])
          ..limit(limit))
        .watch();
  }

  Future<int> createAlertEvent(AlertEventsCompanion entry) =>
      _db.into(_db.alertEvents).insert(entry);

  /// Clears all fired events (used on backup import so stale rule ids
  /// cannot suppress fresh dedup of newly imported rules).
  Future<void> deleteAllAlertEvents() => _db.delete(_db.alertEvents).go();

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
  }) => _db
      .into(_db.syncTombstones)
      .insertOnConflictUpdate(
        SyncTombstonesCompanion.insert(
          table: table,
          rowKey: rowKey,
          deletedAt: Value(deletedAt ?? DateTime.now()),
        ),
      );

  Future<int> removeTombstone(String table, String rowKey) => (_db.delete(
    _db.syncTombstones,
  )..where((t) => t.table.equals(table) & t.rowKey.equals(rowKey))).go();

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
  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);
}
