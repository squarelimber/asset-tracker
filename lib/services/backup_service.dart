import 'dart:convert';

import 'package:drift/drift.dart';

import '../core/formats.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';

/// Result of an import attempt.
class ImportResult {
  const ImportResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

/// JSON backup/restore for all user data.
///
/// The backup format is forward-compatible: unknown fields are ignored,
/// and the version field allows future migrations.
class BackupService {
  BackupService(this._dao);

  final AssetDao _dao;

  static const _version = 2;

  /// Serializes the whole database into a portable JSON string.
  Future<String> exportJson() async {
    final accounts = await _dao.getAccounts();
    final holdings = await _dao.getHoldings();
    final transactions = await _dao.getTransactions();
    final snapshots = await _dao.getSnapshots();
    final rules = await _dao.getAlertRules();

    return jsonEncode({
      'app': 'asset_tracker',
      'version': _version,
      'exportedAt': DateTime.now().toIso8601String(),
      'accounts': accounts.map((a) => _accountToJson(a)).toList(),
      'holdings': holdings.map((h) => _holdingToJson(h)).toList(),
      'transactions': transactions.map((t) => _transactionToJson(t)).toList(),
      'snapshots': snapshots.map((s) => _snapshotToJson(s)).toList(),
      'alertRules': rules.map((r) => _ruleToJson(r)).toList(),
    });
  }

  /// Validates and imports a backup, replacing all existing data.
  Future<ImportResult> importJson(String json) async {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const ImportResult(ok: false, message: '文件不是有效的 JSON');
    }
    if (decoded is! Map<String, dynamic> || decoded['app'] != 'asset_tracker') {
      return const ImportResult(ok: false, message: '不是 asset-tracker 的备份文件');
    }

    final accounts = _parseList(decoded['accounts']);
    final holdings = _parseList(decoded['holdings']);
    final transactions = _parseList(decoded['transactions']);
    final snapshots = _parseList(decoded['snapshots']);
    final rules = _parseList(decoded['alertRules']);

    final problems = _validateReferences(accounts, holdings, transactions);
    if (problems.isNotEmpty) {
      return ImportResult(
        ok: false,
        message: '备份数据不完整，已取消导入：${problems.take(3).join('；')}',
      );
    }

    try {
      await _dao.transaction(() async {
        for (final table in [
          _dao.deleteAllTransactions,
          _dao.deleteAllHoldings,
          _dao.deleteAllAccounts,
          _dao.deleteAllSnapshots,
          _dao.deleteAllAlertRules,
        ]) {
          await table();
        }
        for (final a in accounts) {
          await _dao.createAccount(AccountsCompanion.insert(
            id: _intOrAbsent(a['id']),
            name: a['name']?.toString() ?? '',
            type: a['type']?.toString() ?? 'cash',
            currency: Value(a['currency']?.toString() ?? 'CNY'),
            note: a['note'] == null
                ? const Value.absent()
                : Value(a['note'].toString()),
            createdAt: Value(_parseDate(a['createdAt']) ?? DateTime.now()),
            updatedAt: Value(_parseDate(a['updatedAt']) ?? DateTime.now()),
          ));
        }
        for (final h in holdings) {
          await _dao.createHolding(HoldingsCompanion.insert(
            id: _intOrAbsent(h['id']),
            accountId: (h['accountId'] as num?)?.toInt() ?? 0,
            name: h['name']?.toString() ?? '',
            assetType: h['assetType']?.toString() ?? 'cash',
            marketSource: Value(h['marketSource']?.toString() ?? 'manual'),
            symbol: h['symbol'] == null
                ? const Value.absent()
                : Value(h['symbol'].toString()),
            quantity: Value((h['quantity'] as num?)?.toDouble() ?? 0),
            costPrice: Value((h['costPrice'] as num?)?.toDouble() ?? 0),
            latestPrice: Value((h['latestPrice'] as num?)?.toDouble() ?? 0),
            costFxRate: h['costFxRate'] == null
                ? const Value.absent()
                : Value((h['costFxRate'] as num).toDouble()),
            purchaseDate: h['purchaseDate'] == null
                ? const Value.absent()
                : Value(_parseDate(h['purchaseDate']) ?? DateTime.now()),
            riskLevel: h['riskLevel'] == null
                ? const Value.absent()
                : Value(h['riskLevel'].toString()),
            currency: Value(h['currency']?.toString() ?? 'CNY'),
            note: h['note'] == null
                ? const Value.absent()
                : Value(h['note'].toString()),
            createdAt: Value(_parseDate(h['createdAt']) ?? DateTime.now()),
            updatedAt: Value(_parseDate(h['updatedAt']) ?? DateTime.now()),
          ));
        }
        for (final t in transactions) {
          await _dao.createTransaction(TransactionsCompanion.insert(
            id: _intOrAbsent(t['id']),
            accountId: (t['accountId'] as num?)?.toInt() ?? 0,
            holdingId: t['holdingId'] == null
                ? const Value.absent()
                : Value((t['holdingId'] as num).toInt()),
            cashSourceId: t['cashSourceId'] == null
                ? const Value.absent()
                : Value((t['cashSourceId'] as num).toInt()),
            cashTargetId: t['cashTargetId'] == null
                ? const Value.absent()
                : Value((t['cashTargetId'] as num).toInt()),
            type: t['type']?.toString() ?? 'transfer_in',
            quantity: t['quantity'] == null
                ? const Value.absent()
                : Value((t['quantity'] as num).toDouble()),
            price: t['price'] == null
                ? const Value.absent()
                : Value((t['price'] as num).toDouble()),
            amount: (t['amount'] as num?)?.toDouble() ?? 0,
            currency: Value(t['currency']?.toString() ?? 'CNY'),
            occurredAt: _parseDate(t['occurredAt']) ?? DateTime.now(),
            note: t['note'] == null
                ? const Value.absent()
                : Value(t['note'].toString()),
            costMoved: t['costMoved'] == null
                ? const Value.absent()
                : Value(t['costMoved'] == true),
            updatedAt: Value(_parseDate(t['updatedAt']) ?? DateTime.now()),
          ));
        }
        for (final s in snapshots) {
          await _dao.upsertSnapshot(SnapshotsCompanion.insert(
            date: s['date']?.toString() ?? '',
            currency: Value(s['currency']?.toString() ?? 'CNY'),
            totalValue: (s['totalValue'] as num?)?.toDouble() ?? 0,
            totalCost: (s['totalCost'] as num?)?.toDouble() ?? 0,
            liabilities: Value((s['liabilities'] as num?)?.toDouble() ?? 0),
            createdAt: Value(_parseDate(s['createdAt']) ?? DateTime.now()),
          ));
        }
        for (final r in rules) {
          await _dao.createAlertRule(AlertRulesCompanion.insert(
            id: _intOrAbsent(r['id']),
            type: r['type']?.toString() ?? 'concentration',
            name: r['name']?.toString() ?? '',
            params: Value(r['params']?.toString() ?? '{}'),
            enabled: Value(r['enabled'] == true),
            createdAt: Value(_parseDate(r['createdAt']) ?? DateTime.now()),
            updatedAt: Value(_parseDate(r['updatedAt']) ?? DateTime.now()),
          ));
        }
      });
    } catch (e) {
      return ImportResult(ok: false, message: '导入失败: $e');
    }
    return ImportResult(
      ok: true,
      message: '导入成功：${accounts.length} 账户 / ${holdings.length} 持仓',
    );
  }

  // ---------------------------------------------------------------------------
  // Serialization helpers
  // ---------------------------------------------------------------------------

  List<Map<String, dynamic>> _parseList(Object? value) {
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().toList();
  }

  /// Original row id from a backup entry; backups created before the id
  /// fields were added fall back to auto-increment.
  static Value<int> _intOrAbsent(Object? value) {
    if (value is num) return Value(value.toInt());
    return const Value.absent();
  }

  /// Checks that every foreign reference in the backup points at a row that
  /// is present in the same backup. A backup is a consistent snapshot of one
  /// device, so dangling references mean a corrupted or hand-edited file;
  /// importing it would silently break cost-basis and transfer math.
  static List<String> _validateReferences(
    List<Map<String, dynamic>> accounts,
    List<Map<String, dynamic>> holdings,
    List<Map<String, dynamic>> transactions,
  ) {
    final accountIds = _effectiveIds(accounts);
    final holdingIds = _effectiveIds(holdings);
    final problems = <String>[];
    for (final h in holdings) {
      final accountId = (h['accountId'] as num?)?.toInt();
      if (accountId != null && !accountIds.contains(accountId)) {
        problems.add('持仓「${h['name']}」引用的账户 $accountId 不存在');
      }
    }
    for (final t in transactions) {
      final accountId = (t['accountId'] as num?)?.toInt();
      if (accountId != null && !accountIds.contains(accountId)) {
        problems.add('交易 #${t['id']} 引用的账户 $accountId 不存在');
      }
      for (final field in ['holdingId', 'cashSourceId', 'cashTargetId']) {
        final v = (t[field] as num?)?.toInt();
        if (v != null && !holdingIds.contains(v)) {
          problems.add('交易 #${t['id']} 引用的持仓 $v 不存在');
        }
      }
    }
    return problems;
  }

  /// The id each row will have after import: its explicit backup id, or the
  /// auto-increment value it would receive (the database is emptied first,
  /// so auto ids continue after the largest explicit id).
  static Set<int> _effectiveIds(List<Map<String, dynamic>> rows) {
    var maxExplicit = 0;
    for (final r in rows) {
      final id = (r['id'] as num?)?.toInt() ?? 0;
      if (id > maxExplicit) maxExplicit = id;
    }
    var nextAuto = maxExplicit + 1;
    return {
      for (final r in rows)
        (r['id'] is num) ? (r['id'] as num).toInt() : nextAuto++,
    };
  }

  static DateTime? _parseDate(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value);
  }

  static Map<String, dynamic> _accountToJson(AccountRow a) => {
        'id': a.id,
        'name': a.name,
        'type': a.type,
        'currency': a.currency,
        'note': a.note,
        'createdAt': a.createdAt.toIso8601String(),
        'updatedAt': a.updatedAt.toIso8601String(),
      };

  static Map<String, dynamic> _holdingToJson(HoldingRow h) => {
        'id': h.id,
        'accountId': h.accountId,
        'name': h.name,
        'assetType': h.assetType,
        'marketSource': h.marketSource,
        'symbol': h.symbol,
        'quantity': h.quantity,
        'costPrice': h.costPrice,
        'latestPrice': h.latestPrice,
        'costFxRate': h.costFxRate,
        'purchaseDate': h.purchaseDate?.toIso8601String(),
        'riskLevel': h.riskLevel,
        'currency': h.currency,
        'note': h.note,
        'createdAt': h.createdAt.toIso8601String(),
        'updatedAt': h.updatedAt.toIso8601String(),
      };

  static Map<String, dynamic> _transactionToJson(TransactionRow t) => {
        'id': t.id,
        'accountId': t.accountId,
        'holdingId': t.holdingId,
        'cashSourceId': t.cashSourceId,
        'cashTargetId': t.cashTargetId,
        'type': t.type,
        'quantity': t.quantity,
        'price': t.price,
        'amount': t.amount,
        'currency': t.currency,
        'occurredAt': t.occurredAt.toIso8601String(),
        'note': t.note,
        'costMoved': t.costMoved,
        'updatedAt': t.updatedAt.toIso8601String(),
      };

  static Map<String, dynamic> _snapshotToJson(SnapshotRow s) => {
        'date': s.date,
        'currency': s.currency,
        'totalValue': s.totalValue,
        'totalCost': s.totalCost,
        'liabilities': s.liabilities,
        'createdAt': s.createdAt.toIso8601String(),
      };

  static Map<String, dynamic> _ruleToJson(AlertRuleRow r) => {
        'id': r.id,
        'type': r.type,
        'name': r.name,
        'params': r.params,
        'enabled': r.enabled,
        'createdAt': r.createdAt.toIso8601String(),
        'updatedAt': r.updatedAt.toIso8601String(),
      };
}

/// Suggested file name for exports, e.g. asset_tracker_2026-08-08.json.
String backupFileName([DateTime? now]) =>
    'asset_tracker_${todayKey(now)}.json';
