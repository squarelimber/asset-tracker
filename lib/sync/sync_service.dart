import 'package:drift/drift.dart';

import '../core/history_sync.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import 'sync_api.dart';
import 'sync_format.dart';
import 'sync_merge.dart';

/// Outcome of one sync() run.
class SyncResult {
  const SyncResult({
    required this.ok,
    required this.rev,
    required this.conflicts,
    required this.changed,
    this.message,
    this.dataChanged = false,
  });

  final bool ok;
  final int rev;

  /// Keys edited on both sides, resolved by LWW.
  final int conflicts;

  /// Local rows added/updated/deleted by this sync.
  final int changed;

  /// Whether source-of-truth rows (not derived snapshots) changed locally,
  /// meaning the historical snapshots must be rebuilt.
  final bool dataChanged;

  final String? message;

  static SyncResult fail(String message) =>
      SyncResult(ok: false, rev: 0, conflicts: 0, changed: 0, message: message);
}

/// Settings keys (stored locally, not synced).
abstract final class SyncSettingsKeys {
  static const serverUrl = 'sync.serverUrl';
  static const token = 'sync.token';
  static const autoSync = 'sync.autoSync';
  static const lastRev = 'sync.lastRev';
  static const lastSyncAt = 'sync.lastSyncAt';
}

/// Pulls the remote snapshot, merges it into the local database with
/// last-write-wins, and pushes the merged result back. The server URL and
/// token are read from the local settings on every sync.
class SyncService {
  SyncService(this._dao, {SyncApi Function(String url, String? token)? apiFactory})
      : _apiFactory = apiFactory ?? ((url, token) => SyncApi(url, token: token));

  final AssetDao _dao;
  final SyncApi Function(String url, String? token) _apiFactory;

  static const _formatter = SyncFormatter();

  Future<SyncResult> sync() async {
    try {
      final url = await _dao.getSetting(SyncSettingsKeys.serverUrl);
      if (url == null || url.trim().isEmpty) {
        return SyncResult.fail('未配置同步服务器地址');
      }
      final token = await _dao.getSetting(SyncSettingsKeys.token);
      final api = _apiFactory(url.trim(), token);
      try {
        return await _syncWith(api);
      } finally {
        api.close();
      }
    } on SyncException catch (e) {
      return SyncResult.fail(e.message);
    } catch (e) {
      return SyncResult.fail('同步失败: $e');
    }
  }

  Future<SyncResult> _syncWith(SyncApi api) async {
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final remote = await api.fetch();
      final local = await _exportLocal();
      final outcome = const SyncMerger().merge(
        local: local,
        remote: remote.snapshot,
        remoteTombstones: _parseTombstones(remote.tombstones),
        localTombstones: _parseTombstones(
          (await _dao.getTombstones()).map((t) => t.toJson()).toList(),
        ),
      );

      await _dao.transaction(() async {
        await _apply(outcome);
        await _replaceTombstones(outcome.tombstones);
      });

      final push = await api.push(
        outcome.tables,
        outcome.tombstones.map((t) => t.toJson()).toList(),
        baseRev: remote.rev,
      );
      if (!push.ok) {
        // Someone else wrote to the server while we were merging: re-fetch,
        // re-merge and retry. Re-applying is safe — the merge is LWW and
        // idempotent on already-merged local state.
        continue;
      }

      await _dao.setSetting(SyncSettingsKeys.lastRev, '${push.rev}');
      await _dao.setSetting(
        SyncSettingsKeys.lastSyncAt,
        DateTime.now().toIso8601String(),
      );
      // Derived snapshots must be regenerated from the now-merged source
      // rows, otherwise a freshly-arrived transaction (e.g. a repayment)
      // changes the holdings but leaves stale snapshots, leaking the
      // cash-flow into daily returns. Flag it so the history sync rebuilds
      // the backfill + today.
      if (outcome.dataChanged) {
        await _dao.setSetting(historySyncDirtyKey, historyDirtySet);
      }
      return SyncResult(
        ok: true,
        rev: push.rev,
        conflicts: outcome.conflicts,
        changed: outcome.changed,
        dataChanged: outcome.dataChanged,
      );
    }
    return SyncResult.fail('同步冲突：服务器被并发更新，请重试');
  }

  Future<Map<String, dynamic>> _exportLocal() async {
    return _formatter.snapshot(
      accounts: await _dao.getAccounts(),
      holdings: await _dao.getHoldings(),
      transactions: await _dao.getTransactions(),
      snapshots: await _dao.getSnapshots(),
      alertRules: await _dao.getAlertRules(),
    );
  }

  Future<void> _apply(MergeOutcome outcome) async {
    // Delete first so a merged re-creation can re-insert freely.
    for (final table in SyncTables.all) {
      for (final key in outcome.deletedKeys[table] ?? const <String>[]) {
        await _deleteLocalRow(table, key);
      }
    }
    for (final table in SyncTables.all) {
      for (final row in outcome.tables[table] ?? const <Map<String, dynamic>>[]) {
        await _upsertLocalRow(table, row);
      }
    }
  }

  Future<void> _deleteLocalRow(String table, String key) async {
    switch (table) {
      case SyncTables.accounts: {
        final id = int.tryParse(key);
        if (id == null) return;
        await _dao.deleteAccount(id);
      }
      case SyncTables.holdings: {
        final id = int.tryParse(key);
        if (id == null) return;
        await _dao.deleteHolding(id);
      }
      case SyncTables.transactions: {
        final id = int.tryParse(key);
        if (id == null) return;
        await _dao.deleteTransaction(id);
      }
      case SyncTables.snapshots: {
        final parts = key.split('|');
        final date = parts[0];
        final currency = parts.length > 1 ? parts[1] : 'CNY';
        await _dao.deleteSnapshot(date, currency);
      }
      case SyncTables.alertRules: {
        final id = int.tryParse(key);
        if (id == null) return;
        await _dao.deleteAlertRule(id);
      }
    }
  }

  Future<void> _upsertLocalRow(String table, Map<String, dynamic> row) async {
    final updatedAt = parseIso(row['updatedAt']) ?? DateTime.now();
    switch (table) {
      case SyncTables.accounts:
        final id = (row['id'] as num?)?.toInt();
        if (id == null) return;
        if (await _dao.getAccount(id) != null) {
          await _dao.updateAccount(_rowToAccount(row), now: updatedAt);
        } else {
          await _dao.createAccount(AccountsCompanion.insert(
            id: Value(id),
            name: row['name']?.toString() ?? '',
            type: row['type']?.toString() ?? 'cash',
            currency: Value(row['currency']?.toString() ?? 'CNY'),
            note: row['note'] == null ? const Value.absent() : Value(row['note'].toString()),
            createdAt: Value(parseIso(row['createdAt']) ?? DateTime.now()),
            updatedAt: Value(updatedAt),
          ));
        }
      case SyncTables.holdings:
        final id = (row['id'] as num?)?.toInt();
        if (id == null) return;
        if (await _dao.getHolding(id) != null) {
          await _dao.updateHolding(_rowToHolding(row), now: updatedAt);
        } else {
          await _dao.createHolding(HoldingsCompanion.insert(
            id: Value(id),
            accountId: (row['accountId'] as num?)?.toInt() ?? 0,
            name: row['name']?.toString() ?? '',
            assetType: row['assetType']?.toString() ?? 'cash',
            marketSource: Value(row['marketSource']?.toString() ?? 'manual'),
            symbol: row['symbol'] == null ? const Value.absent() : Value(row['symbol'].toString()),
            quantity: Value((row['quantity'] as num?)?.toDouble() ?? 0),
            costPrice: Value((row['costPrice'] as num?)?.toDouble() ?? 0),
            latestPrice: Value((row['latestPrice'] as num?)?.toDouble() ?? 0),
            costFxRate: row['costFxRate'] == null
                ? const Value.absent()
                : Value((row['costFxRate'] as num).toDouble()),
            purchaseDate: parseIso(row['purchaseDate']) == null
                ? const Value.absent()
                : Value(parseIso(row['purchaseDate'])!),
            riskLevel: row['riskLevel'] == null
                ? const Value.absent()
                : Value(row['riskLevel'].toString()),
            currency: Value(row['currency']?.toString() ?? 'CNY'),
            note: row['note'] == null ? const Value.absent() : Value(row['note'].toString()),
            createdAt: Value(parseIso(row['createdAt']) ?? DateTime.now()),
            updatedAt: Value(updatedAt),
          ));
        }
      case SyncTables.transactions:
        final id = (row['id'] as num?)?.toInt();
        if (id == null) return;
        if (await _dao.getTransaction(id) != null) {
          await _dao.updateTransaction(_rowToTransaction(row), now: updatedAt);
        } else {
          await _dao.createTransaction(TransactionsCompanion.insert(
            id: Value(id),
            accountId: (row['accountId'] as num?)?.toInt() ?? 0,
            holdingId: row['holdingId'] == null
                ? const Value.absent()
                : Value((row['holdingId'] as num).toInt()),
            cashSourceId: row['cashSourceId'] == null
                ? const Value.absent()
                : Value((row['cashSourceId'] as num).toInt()),
            cashTargetId: row['cashTargetId'] == null
                ? const Value.absent()
                : Value((row['cashTargetId'] as num).toInt()),
            type: row['type']?.toString() ?? 'transfer_in',
            quantity: row['quantity'] == null
                ? const Value.absent()
                : Value((row['quantity'] as num).toDouble()),
            price: row['price'] == null
                ? const Value.absent()
                : Value((row['price'] as num).toDouble()),
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            currency: Value(row['currency']?.toString() ?? 'CNY'),
            occurredAt: parseIso(row['occurredAt']) ?? DateTime.now(),
            note: row['note'] == null ? const Value.absent() : Value(row['note'].toString()),
            costMoved: row['costMoved'] == null
                ? const Value.absent()
                : Value(row['costMoved'] == true),
            updatedAt: Value(updatedAt),
          ));
        }
      case SyncTables.snapshots:
        final date = row['date']?.toString() ?? '';
        if (date.isEmpty) return;
        final currency = row['currency']?.toString() ?? 'CNY';
        await _dao.upsertSnapshot(SnapshotsCompanion.insert(
          date: date,
          currency: Value(currency),
          totalValue: (row['totalValue'] as num?)?.toDouble() ?? 0,
          totalCost: (row['totalCost'] as num?)?.toDouble() ?? 0,
          liabilities: Value((row['liabilities'] as num?)?.toDouble() ?? 0),
          createdAt: Value(parseIso(row['createdAt']) ?? DateTime.now()),
        ));
      case SyncTables.alertRules:
        final id = (row['id'] as num?)?.toInt();
        if (id == null) return;
        if (await _dao.getAlertRule(id) != null) {
          await _dao.updateAlertRule(_rowToRule(row), now: updatedAt);
        } else {
          await _dao.createAlertRule(AlertRulesCompanion.insert(
            id: Value(id),
            type: row['type']?.toString() ?? 'concentration',
            name: row['name']?.toString() ?? '',
            params: Value(row['params']?.toString() ?? '{}'),
            enabled: Value(row['enabled'] == true),
            createdAt: Value(parseIso(row['createdAt']) ?? DateTime.now()),
            updatedAt: Value(updatedAt),
          ));
        }
    }
  }

  Future<void> _replaceTombstones(List<TombstoneEntry> tombstones) async {
    await _dao.deleteAllTombstones();
    for (final t in tombstones) {
      await _dao.upsertTombstone(t.table, t.rowKey, deletedAt: t.deletedAt);
    }
  }

  static List<TombstoneEntry> _parseTombstones(List<dynamic> raw) =>
      raw.map(TombstoneEntry.fromJson).whereType<TombstoneEntry>().toList();

  // Row -> data class conversions (kept here to avoid touching the DAO).
  static AccountRow _rowToAccount(Map<String, dynamic> row) => AccountRow(
        id: (row['id'] as num).toInt(),
        name: row['name']?.toString() ?? '',
        type: row['type']?.toString() ?? 'cash',
        currency: row['currency']?.toString() ?? 'CNY',
        note: row['note'] as String?,
        createdAt: parseIso(row['createdAt']) ?? DateTime.now(),
        updatedAt: parseIso(row['updatedAt']) ?? DateTime.now(),
      );

  static HoldingRow _rowToHolding(Map<String, dynamic> row) => HoldingRow(
        id: (row['id'] as num).toInt(),
        accountId: (row['accountId'] as num?)?.toInt() ?? 0,
        name: row['name']?.toString() ?? '',
        assetType: row['assetType']?.toString() ?? 'cash',
        marketSource: row['marketSource']?.toString() ?? 'manual',
        symbol: row['symbol'] as String?,
        quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
        costPrice: (row['costPrice'] as num?)?.toDouble() ?? 0,
        latestPrice: (row['latestPrice'] as num?)?.toDouble() ?? 0,
        costFxRate: (row['costFxRate'] as num?)?.toDouble(),
        purchaseDate: parseIso(row['purchaseDate']),
        riskLevel: row['riskLevel'] as String?,
        currency: row['currency']?.toString() ?? 'CNY',
        note: row['note'] as String?,
        createdAt: parseIso(row['createdAt']) ?? DateTime.now(),
        updatedAt: parseIso(row['updatedAt']) ?? DateTime.now(),
      );

  static TransactionRow _rowToTransaction(Map<String, dynamic> row) => TransactionRow(
        id: (row['id'] as num).toInt(),
        accountId: (row['accountId'] as num?)?.toInt() ?? 0,
        holdingId: (row['holdingId'] as num?)?.toInt(),
        cashSourceId: (row['cashSourceId'] as num?)?.toInt(),
        cashTargetId: (row['cashTargetId'] as num?)?.toInt(),
        type: row['type']?.toString() ?? 'transfer_in',
        quantity: (row['quantity'] as num?)?.toDouble(),
        price: (row['price'] as num?)?.toDouble(),
        amount: (row['amount'] as num?)?.toDouble() ?? 0,
        currency: row['currency']?.toString() ?? 'CNY',
        occurredAt: parseIso(row['occurredAt']) ?? DateTime.now(),
        note: row['note'] as String?,
        costMoved: row['costMoved'] == null ? true : row['costMoved'] == true,
        updatedAt: parseIso(row['updatedAt']) ?? DateTime.now(),
      );

  static AlertRuleRow _rowToRule(Map<String, dynamic> row) => AlertRuleRow(
        id: (row['id'] as num).toInt(),
        type: row['type']?.toString() ?? 'concentration',
        name: row['name']?.toString() ?? '',
        params: row['params']?.toString() ?? '{}',
        enabled: row['enabled'] == true,
        createdAt: parseIso(row['createdAt']) ?? DateTime.now(),
        updatedAt: parseIso(row['updatedAt']) ?? DateTime.now(),
      );
}
