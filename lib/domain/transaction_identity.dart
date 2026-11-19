import '../core/enums.dart';
import '../data/database.dart';

extension TransactionHistoryTimestamp on TransactionRow {
  DateTime get historyUpdatedAt => ledgerUpdatedAt ?? updatedAt;
}

bool isExternalSale(TransactionRow row) =>
    row.type == TransactionType.sell.storageName &&
    !row.internalMove && row.cashTargetId == null && row.holdingId != null;

bool isRedemptionLeg(TransactionRow row) =>
    row.internalMove &&
    row.holdingId != null &&
    row.cashSourceId == null &&
    row.cashTargetId == null &&
    (row.type == TransactionType.buy.storageName ||
        row.type == TransactionType.sell.storageName);

bool hasSameRedemption(TransactionRow a, TransactionRow b) {
  if (!isRedemptionLeg(a) || !isRedemptionLeg(b)) return false;
  final group = a.redemptionGroup;
  if (group != null || b.redemptionGroup != null) {
    return group != null && group == b.redemptionGroup;
  }
  return a.occurredAt.isAtSameMomentAs(b.occurredAt) &&
      a.amount == b.amount &&
      a.currency.toUpperCase() == b.currency.toUpperCase() &&
      a.costMovedAmount == b.costMovedAmount;
}

/// Pre-group records only have enough information to act when exactly one
/// buy and one sell match. Never guess when multiple operations match.
TransactionRow? redemptionPartner(
  TransactionRow row,
  Iterable<TransactionRow> candidates,
) {
  if (!isRedemptionLeg(row)) return null;
  final group = candidates
      .where((other) => hasSameRedemption(row, other))
      .toList();
  final opposite = group.where((other) => other.type != row.type).toList();
  if (opposite.isEmpty && row.redemptionGroup == null) return null;
  if (group.length != 2 ||
      opposite.length != 1 ||
      opposite.single.holdingId == row.holdingId) {
    throw ArgumentError('关联的赎回与买入流水无法唯一匹配，账本未修改');
  }
  return opposite.single;
}

// Ordinary legacy rows were assigned sequential IDs. Reserve the negative
// range for that order, including rows renumbered during a legacy sync.
int legacyTransactionEntryOrder(int id) => id - 4503599627370496;

int compareTransactionEntryOrder(TransactionRow a, TransactionRow b) {
  final aOrder = a.recordedAtMicros ?? legacyTransactionEntryOrder(a.id);
  final bOrder = b.recordedAtMicros ?? legacyTransactionEntryOrder(b.id);
  final byTime = aOrder.compareTo(bOrder);
  return byTime == 0 ? a.id.compareTo(b.id) : byTime;
}
