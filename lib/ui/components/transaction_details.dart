import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../data/database.dart';
import '../tokens.dart';
import 'transaction_presentation.dart';

/// Shows the values recorded on this transaction, without deriving missing
/// prices or quantities from the current holding.
Future<void> showTransactionDetails(
  BuildContext context,
  TransactionRow transaction, {
  Future<void> Function()? onEditDate,
}) async {
  final edit = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _TransactionDetails(
      transaction: transaction,
      canEditDate: onEditDate != null,
    ),
  );
  if (edit == true && onEditDate != null && context.mounted) await onEditDate();
}

class _TransactionDetails extends ConsumerWidget {
  const _TransactionDetails({
    required this.transaction,
    required this.canEditDate,
  });

  final TransactionRow transaction;
  final bool canEditDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hide = ref.watch(hideAmountsProvider);
    final holdings =
        ref.watch(holdingsProvider).valueOrNull ?? const <HoldingRow>[];
    final accounts =
        ref.watch(accountsProvider).valueOrNull ?? const <AccountRow>[];
    HoldingRow? findHolding(int? id) {
      for (final holding in holdings) {
        if (holding.id == id) return holding;
      }
      return null;
    }

    String? accountName(int id) {
      for (final account in accounts) {
        if (account.id == id) return account.name;
      }
      return null;
    }

    final type = TransactionType.fromStorage(transaction.type);
    final repayment = repaymentOf(
      transaction,
      findHolding(transaction.cashSourceId),
      findHolding(transaction.cashTargetId),
    );
    final product = findHolding(transaction.holdingId);
    final isAmountBased =
        product != null &&
        AssetType.values.any(
          (type) => type.storageName == product.assetType && type.isAmountBased,
        );
    String? counterparty(int? id) {
      final holding = findHolding(id);
      if (holding == null) return null;
      final account = accountName(holding.accountId);
      return account == null ? holding.name : '$account / ${holding.name}';
    }

    final (counterpartyLabel, counterpartyId) = switch (type) {
      TransactionType.buy => ('扣款来源', transaction.cashSourceId),
      TransactionType.sell ||
      TransactionType.dividend ||
      TransactionType.income => ('入账', transaction.cashTargetId),
      TransactionType.expense => ('扣款', transaction.cashTargetId),
      _ => (null, null),
    };
    final note = transaction.note?.trim();
    final rows = <(String, String)>[
      ('交易类型', repayment?.label ?? type.label),
      (
        '交易时间',
        DateFormat('yyyy-MM-dd HH:mm').format(transaction.occurredAt.toLocal()),
      ),
      if (product != null) ('产品', product.name),
      if (accountName(transaction.accountId) case final name?) ('账户', name),
      if (counterpartyLabel != null)
        if (counterparty(counterpartyId) case final name?)
          (counterpartyLabel, name),
      if (type == TransactionType.transferIn ||
          type == TransactionType.transferOut) ...[
        if (counterparty(transaction.cashSourceId) case final name?)
          (repayment == null ? '来源' : '资金来源', name),
        if (counterparty(transaction.cashTargetId) case final name?)
          (repayment == null ? '去向' : '还款账户', name),
      ],
      if (!isAmountBased) ...[
        if (transaction.price case final price?)
          ('成交价', hide ? '****' : Formats.plainNum(price, decimals: 6)),
        if (transaction.quantity case final quantity?)
          ('数量', hide ? '****' : Formats.plainNum(quantity, decimals: 6)),
      ],
      if (type == TransactionType.split)
        (
          '折算比例',
          hide
              ? '****'
              : '×${Formats.plainNum(transaction.amount, decimals: 6)}',
        )
      else
        (
          '金额',
          hide
              ? '****'
              : Formats.money(transaction.amount, transaction.currency),
        ),
      if (note != null && note.isNotEmpty) ('备注', note),
    ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(T.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '交易详情',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (canEditDate)
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('修改日期'),
                    ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: T.s2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 80,
                        child: Text(label, style: T.label(size: 13)),
                      ),
                      Expanded(
                        child: Text(
                          value,
                          textAlign: TextAlign.right,
                          style: T.mono(size: 13),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
