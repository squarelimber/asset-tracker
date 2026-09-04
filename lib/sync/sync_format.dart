import '../data/database.dart';

/// Table names used by the sync protocol.
abstract final class SyncTables {
  static const accounts = 'accounts';
  static const holdings = 'holdings';
  static const transactions = 'transactions';
  static const snapshots = 'snapshots';
  static const alertRules = 'alertRules';

  static const all = [accounts, holdings, transactions, snapshots, alertRules];
}

/// Row-key of a synced row: the integer id for id-keyed tables and the
/// composite 'date|currency' key for snapshots.
String syncRowKey(String table, Map<String, dynamic> row) {
  if (table == SyncTables.snapshots) {
    return '${row['date']}|${row['currency'] ?? 'CNY'}';
  }
  return '${row['id']}';
}

/// Serializes the database into the sync snapshot format:
/// { accounts: [...], holdings: [...], transactions: [...], snapshots: [...], alertRules: [...] }.
/// All rows carry every column, including `updatedAt` (ISO-8601).
class SyncFormatter {
  const SyncFormatter();

  Map<String, dynamic> snapshot({
    required List<AccountRow> accounts,
    required List<HoldingRow> holdings,
    required List<TransactionRow> transactions,
    required List<SnapshotRow> snapshots,
    required List<AlertRuleRow> alertRules,
  }) {
    return {
      SyncTables.accounts: accounts.map(accountToRow).toList(),
      SyncTables.holdings: holdings.map(holdingToRow).toList(),
      SyncTables.transactions: transactions.map(transactionToRow).toList(),
      SyncTables.snapshots: snapshots.map(snapshotToRow).toList(),
      SyncTables.alertRules: alertRules.map(ruleToRow).toList(),
    };
  }

  Map<String, dynamic> accountToRow(AccountRow a) => {
        'id': a.id,
        'name': a.name,
        'type': a.type,
        'currency': a.currency,
        'note': a.note,
        'createdAt': a.createdAt.toIso8601String(),
        'updatedAt': a.updatedAt.toIso8601String(),
      };

  Map<String, dynamic> holdingToRow(HoldingRow h) => {
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
        'archived': h.archived,
        'createdAt': h.createdAt.toIso8601String(),
        'updatedAt': h.updatedAt.toIso8601String(),
      };

  Map<String, dynamic> transactionToRow(TransactionRow t) => {
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

  Map<String, dynamic> snapshotToRow(SnapshotRow s) => {
        'date': s.date,
        'currency': s.currency,
        'totalValue': s.totalValue,
        'totalCost': s.totalCost,
        'liabilities': s.liabilities,
        'createdAt': s.createdAt.toIso8601String(),
        'updatedAt': s.createdAt.toIso8601String(),
      };

  Map<String, dynamic> ruleToRow(AlertRuleRow r) => {
        'id': r.id,
        'type': r.type,
        'name': r.name,
        'params': r.params,
        'enabled': r.enabled,
        'createdAt': r.createdAt.toIso8601String(),
        'updatedAt': r.updatedAt.toIso8601String(),
      };
}

DateTime? parseIso(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}
