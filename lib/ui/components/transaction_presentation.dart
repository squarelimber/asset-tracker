import '../../core/enums.dart';
import '../../data/database.dart';

bool isTransferRecord(TransactionRow transaction) =>
    transaction.type == TransactionType.transferIn.storageName ||
    transaction.type == TransactionType.transferOut.storageName;

/// A transfer from a balance asset into a liability is a repayment.
/// Both endpoints are required to distinguish it from borrowing or a transfer.
({HoldingRow source, HoldingRow target, String label})? repaymentOf(
  TransactionRow transaction,
  HoldingRow? source,
  HoldingRow? target,
) {
  if (!isTransferRecord(transaction)) return null;
  if (source == null ||
      target == null ||
      !AssetType.values.any(
        (type) => type.storageName == source.assetType && type.isAmountBased,
      ) ||
      target.assetType != AssetType.liability.storageName) {
    return null;
  }
  return (
    source: source,
    target: target,
    // The holding type is shared by credit cards and other debt.
    label: target.name.contains('信用卡') ? '信用卡还款' : '还款',
  );
}
