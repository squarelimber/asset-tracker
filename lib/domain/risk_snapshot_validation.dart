import 'dart:math' as math;

import '../core/enums.dart';
import '../data/database.dart';
import 'cash_flow_adjustments.dart';
import 'holding_valuation.dart';
import 'transaction_identity.dart';

bool _close(double a, double b) =>
    a.isFinite &&
    b.isFinite &&
    (a - b).abs() <= math.max(1e-6, math.max(a.abs(), b.abs()) * 1e-10);

/// Verifies principal and cumulative realized gains against the recorded
/// transactions for one adjacent pair of daily CNY snapshots. It never
/// infers a flow's principal or historical FX rate from the very cost
/// difference being checked.
String? riskSnapshotValidationIssue(
  SnapshotRow previous,
  SnapshotRow current,
  List<TransactionRow> transactions,
) {
  final beforeValues = snapshotHoldingValues(previous);
  final afterValues = snapshotHoldingValues(current);
  if (beforeValues == null || afterValues == null) {
    if ((beforeValues == null && previous.holdingValues != null) ||
        (afterValues == null && current.holdingValues != null)) {
      return '持仓快照明细与汇总无法核对';
    }
    if (transactions.isNotEmpty) return '交易流水缺少可核对的持仓快照';
    if (!_close(previous.totalCost, current.totalCost)) {
      return '本金变化缺少可核对的流水';
    }
    if (!_close(previous.realizedProfit ?? 0, current.realizedProfit ?? 0)) {
      return '已实现收益变化缺少可核对的流水';
    }
    if (!_close(
      previous.profitAdjustment ?? 0,
      current.profitAdjustment ?? 0,
    )) {
      return '收益调整变化缺少可核对的流水';
    }
    return null;
  }
  final before = {for (final value in beforeValues) value.holdingId: value};
  final after = {for (final value in afterValues) value.holdingId: value};
  if ([
    ...beforeValues,
    ...afterValues,
  ].any((value) => !value.liability && value.cost < 0)) {
    return '持仓本金无效';
  }
  final identities = {...before, ...after};
  final costs = <int, double>{
    for (final id in identities.keys) id: before[id]?.cost ?? 0,
  };
  final realized = <int, double>{
    for (final id in identities.keys) id: before[id]?.realizedProfit ?? 0,
  };
  for (final id in before.keys) {
    if (after[id] case final value?) {
      if (before[id]!.type != value.type) return '持仓类型变化无法核对本金';
    }
  }

  DayHoldingValue? asset(int? id) {
    final value = identities[id];
    return value == null || value.liability ? null : value;
  }

  bool cash(int? id) => asset(id)?.type.isAmountBased ?? false;
  bool share(int? id) {
    final value = asset(id);
    return value != null && !value.type.isAmountBased;
  }

  bool amount(double? value) => value != null && value.isFinite && value >= 0;
  bool add(int? id, double delta) {
    if (asset(id) == null || !delta.isFinite) return false;
    final updated = costs[id]! + delta;
    if (updated < -math.max(1e-6, costs[id]!.abs() * 1e-10)) return false;
    costs[id!] = math.max(0.0, updated);
    return true;
  }

  final ordered = [...transactions]
    ..sort((a, b) {
      final byTime = a.occurredAt.compareTo(b.occurredAt);
      return byTime == 0 ? compareTransactionEntryOrder(a, b) : byTime;
    });
  bool liabilityOpening(TransactionRow row) {
    final id = row.holdingId;
    final initial = before[id];
    final closing = after[id];
    if (row.type != TransactionType.transferOut.storageName ||
        row.opensHolding != true ||
        id == null ||
        id != row.cashSourceId ||
        id != row.cashTargetId ||
        closing == null ||
        !closing.liability ||
        (initial != null &&
            (!initial.liability || !_close(initial.value, 0))) ||
        !_close(initial?.cost ?? 0, closing.cost) ||
        !amount(row.costMovedAmount) ||
        !_close(row.costMovedAmount!, row.amount)) {
      return false;
    }
    var otherChange = 0.0;
    for (final other in ordered) {
      if (identical(other, row)) continue;
      if (other.holdingId != id &&
          other.cashSourceId != id &&
          other.cashTargetId != id) {
        continue;
      }
      if (!other.amount.isFinite || other.amount <= 0) return false;
      switch (other.type) {
        case 'consume':
          if (other.holdingId == id) otherChange += other.amount;
        case 'transfer_in' || 'transfer_out':
          // Only the recorded initialization may point both legs at itself.
          if (other.cashSourceId == other.cashTargetId) return false;
          if (other.cashSourceId == id) otherChange += other.amount;
          if (other.cashTargetId == id) otherChange -= other.amount;
        default:
          return false;
      }
    }
    return _close(
      closing.value - (initial?.value ?? 0) - otherChange,
      row.amount,
    );
  }

  for (final transaction in ordered) {
    if (transaction.currency.toUpperCase() != 'CNY') {
      return '交易流水缺少可核对的历史人民币折算';
    }
    if (!transaction.amount.isFinite ||
        transaction.amount < 0 ||
        (transaction.amount == 0 &&
            !(transaction.type == 'buy' && transaction.opensHolding == true))) {
      return '交易流水金额无效';
    }
    final type = TransactionType.values
        .where((value) => value.storageName == transaction.type)
        .firstOrNull;
    if (type == null) return '交易流水类型无法核对';
    final subject = transaction.holdingId;
    final source = transaction.cashSourceId;
    final target = transaction.cashTargetId;
    final recordedPrincipal = transaction.costMovedAmount;
    final moved = recordedPrincipal ?? double.nan;
    var valid = true;
    switch (type) {
      case TransactionType.buy:
        if (!amount(transaction.quantity) ||
            transaction.quantity! <= 0 ||
            asset(subject) == null) {
          valid = false;
          break;
        }
        if (source != null) {
          valid =
              source != subject &&
              cash(source) &&
              amount(recordedPrincipal) &&
              add(source, -moved) &&
              add(subject, moved);
        } else if (transaction.internalMove) {
          final partner = _redemptionPartner(transaction, ordered);
          valid =
              partner != null &&
              asset(partner.holdingId) != null &&
              amount(recordedPrincipal) &&
              moved == partner.costMovedAmount &&
              add(subject, moved);
        } else {
          valid = share(subject) && add(subject, transaction.amount);
        }
      case TransactionType.sell:
        if (!amount(transaction.quantity) ||
            transaction.quantity! <= 0 ||
            asset(subject) == null) {
          valid = false;
          break;
        }
        if (target != null) {
          valid =
              target != subject &&
              cash(target) &&
              amount(recordedPrincipal) &&
              add(subject, -moved) &&
              add(target, moved);
        } else if (transaction.internalMove) {
          final partner = _redemptionPartner(transaction, ordered);
          valid =
              partner != null &&
              asset(partner.holdingId) != null &&
              amount(recordedPrincipal) &&
              moved == partner.costMovedAmount &&
              add(subject, -moved);
        } else {
          final principal = transaction.externalSellPrincipal;
          if (principal == null || !amount(principal)) {
            valid = false;
          } else {
            valid = add(subject, -principal);
            if (valid) {
              final id = subject!;
              realized[id] = realized[id]! + transaction.amount - principal;
            }
          }
        }
      case TransactionType.transferIn || TransactionType.transferOut:
        final from = identities[source];
        final to = identities[target];
        if (source == target) {
          valid = liabilityOpening(transaction);
          break;
        }
        if (source == target ||
            from == null ||
            to == null ||
            !(from.liability || from.type.isAmountBased) ||
            !(to.liability || to.type.isAmountBased)) {
          valid = false;
          break;
        }
        if (transaction.costMoved) {
          valid =
              amount(recordedPrincipal) &&
              (from.liability || add(source, -moved)) &&
              (to.liability || add(target, moved));
        }
      case TransactionType.income:
        final principal = recordedPrincipal ?? transaction.amount;
        valid =
            cash(target) &&
            amount(principal) &&
            (transaction.opensHolding == true ||
                _close(principal, transaction.amount)) &&
            add(target, principal);
      case TransactionType.expense:
        final principal = recordedPrincipal ?? transaction.amount;
        valid = cash(target) && amount(principal) && add(target, -principal);
      case TransactionType.dividend:
        valid = cash(target) && (subject == null || asset(subject) != null);
        if (valid && share(subject)) {
          valid = add(subject, -math.min(costs[subject]!, transaction.amount));
        }
      case TransactionType.consume:
        valid = identities[subject]?.liability ?? false;
      case TransactionType.split:
        valid = share(subject);
    }
    if (!valid) return '交易流水的本金或关联持仓无法核对';
  }
  for (final entry in identities.entries) {
    if (entry.value.liability) continue;
    final id = entry.key;
    if (!_close(costs[id]!, after[id]?.cost ?? 0)) {
      return '本金变化与相关持仓流水不一致';
    }
    if (!_close(realized[id]!, after[id]?.realizedProfit ?? 0)) {
      return '已实现收益变化与卖出流水不一致';
    }
  }
  final needsCorrectedHistory = ordered.any((transaction) {
    if (transaction.type == TransactionType.expense.storageName) return true;
    if ((transaction.type == TransactionType.transferIn.storageName ||
            transaction.type == TransactionType.transferOut.storageName) &&
        cash(transaction.cashSourceId) &&
        identities[transaction.cashTargetId]?.liability == true) {
      return true;
    }
    return transaction.type == TransactionType.dividend.storageName &&
        share(transaction.holdingId);
  });
  if (needsCorrectedHistory &&
      (previous.profitAdjustment == null || current.profitAdjustment == null)) {
    return '现金收支或分红快照仍为旧收益口径，请重建历史快照';
  }
  final adjustments = cashFlowAdjustmentsBetween(
    previous,
    current,
    transactions: ordered,
  );
  if (!adjustments.verified) return adjustments.issue ?? '收益调整无法核对';
  if (!_close(adjustments.total, current.profitAdjustment ?? 0)) {
    return '收益调整与相关流水不一致';
  }
  for (final id in identities.keys) {
    if (!_close(
      adjustments.byHolding[id] ?? 0,
      after[id]?.profitAdjustment ?? 0,
    )) {
      return '持仓收益调整与相关流水不一致';
    }
  }
  return null;
}

TransactionRow? _redemptionPartner(
  TransactionRow transaction,
  List<TransactionRow> transactions,
) {
  try {
    final partner = redemptionPartner(transaction, transactions);
    if (partner == null ||
        partner.amount != transaction.amount ||
        partner.currency.toUpperCase() != transaction.currency.toUpperCase()) {
      return null;
    }
    return partner;
  } on ArgumentError {
    return null;
  }
}
