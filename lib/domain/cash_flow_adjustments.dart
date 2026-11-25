import 'package:drift/drift.dart' show Value;

import '../core/enums.dart';
import '../core/formats.dart';
import '../data/database.dart';
import 'holding_valuation.dart';
import 'transaction_identity.dart';

/// Cumulative corrections to the cost-basis view. These are bookkeeping
/// adjustments, separate from realized gains on sales.
class CashFlowAdjustmentResult {
  const CashFlowAdjustmentResult({
    required this.total,
    required this.byHolding,
    required this.values,
    this.verified = true,
    this.issue,
  });

  final double total;
  final Map<int, double> byHolding;
  final List<DayHoldingValue> values;
  final bool verified;
  final String? issue;

  SnapshotRow applyTo(SnapshotRow snapshot) {
    if (!verified) throw StateError(issue ?? '现金流水收益调整待核对');
    return snapshot.copyWith(
      profitAdjustment: Value(total),
      holdingValues: Value(encodeHoldingValues(values)),
    );
  }
}

/// Advances the correction between two recorded CNY valuations. The first
/// observation is a baseline; same-day rewrites must use a strictly earlier
/// snapshot so a payout is never applied twice.
///
/// Only transactions that remove earned gain from tracked assets or pay a
/// linked share dividend need a correction. Unrelated buys, incoming cash,
/// splits and transfers between assets do not invalidate this calculation.
CashFlowAdjustmentResult cashFlowAdjustmentsBetween(
  SnapshotRow? previous,
  SnapshotRow current, {
  required List<TransactionRow> transactions,
  Map<int, double> replayedPrincipal = const {},
}) {
  final afterValues = snapshotHoldingValues(current);
  final beforeValues = previous == null
      ? null
      : snapshotHoldingValues(previous);
  final after = {
    for (final value in afterValues ?? <DayHoldingValue>[])
      value.holdingId: value,
  };
  final before = {
    for (final value in beforeValues ?? <DayHoldingValue>[])
      value.holdingId: value,
  };
  final identities = {...before, ...after};
  final adjustments = <int, double>{
    for (final value in before.values)
      if (!value.liability && value.profitAdjustment != 0)
        value.holdingId: value.profitAdjustment,
  };

  CashFlowAdjustmentResult result({String? issue}) {
    final values = <DayHoldingValue>[
      for (final value in after.values)
        value.withProfitAdjustment(adjustments[value.holdingId] ?? 0),
      // Keep a zero-valued identity if a corrected position disappeared.
      // Its cumulative adjustment must not vanish on the next observation.
      for (final entry in adjustments.entries)
        if (!after.containsKey(entry.key) && entry.value != 0)
          DayHoldingValue(
            holdingId: entry.key,
            name: identities[entry.key]!.name,
            type: identities[entry.key]!.type,
            value: 0,
            cost: 0,
            liability: false,
            profitAdjustment: entry.value,
          ),
    ];
    return CashFlowAdjustmentResult(
      total: adjustments.values.fold(0.0, (sum, value) => sum + value),
      byHolding: Map.unmodifiable(adjustments),
      values: List.unmodifiable(values),
      verified: issue == null,
      issue: issue,
    );
  }

  if (afterValues == null) return result(issue: '当日快照缺少可核对的持仓明细。');
  if (previous == null) return result();
  if (previous.date.compareTo(current.date) >= 0) {
    return result(issue: '收益调整须使用严格早于当日的快照基线。');
  }
  if (previous.profitAdjustment != null && beforeValues == null) {
    return result(issue: '上一快照缺少累计收益调整明细，请重建历史快照。');
  }
  final interval = transactions.where((row) {
    final day = todayKey(row.occurredAt.toLocal());
    return day.compareTo(previous.date) > 0 && day.compareTo(current.date) <= 0;
  }).toList();
  void add(int id, double amount) {
    adjustments.update(id, (value) => value + amount, ifAbsent: () => amount);
  }

  String? check(TransactionRow row) {
    if (row.historyUpdatedAt.isAfter(current.createdAt)) {
      return '流水晚于收益快照更新，请重建历史快照。';
    }
    if (row.currency.toUpperCase() != 'CNY') {
      return '缺少 ${row.currency.toUpperCase()} 的历史折算依据，现金流水收益调整待核对。';
    }
    if (!row.amount.isFinite || row.amount < 0) return '现金流水金额无效。';
    return null;
  }

  final dividends = <int, List<TransactionRow>>{};
  for (final row in interval) {
    if (row.type == TransactionType.dividend.storageName) {
      if (row.holdingId == null) continue;
      final source = identities[row.holdingId];
      final target = identities[row.cashTargetId];
      // A standalone cash dividend is genuine new investment income.
      if (source == null) {
        return result(issue: '关联分红缺少来源持仓明细，收益调整待核对。');
      }
      if (source.liability || source.type.isAmountBased) continue;
      if (target == null || target.liability || !target.type.isAmountBased) {
        return result(issue: '关联分红缺少现金入账明细，收益调整待核对。');
      }
      final issue = check(row);
      if (issue != null) return result(issue: issue);
      (dividends[source.holdingId] ??= []).add(row);
      continue;
    }
    final expense = row.type == TransactionType.expense.storageName;
    final transfer =
        row.type == TransactionType.transferIn.storageName ||
        row.type == TransactionType.transferOut.storageName;
    final sourceId = expense ? row.cashTargetId : row.cashSourceId;
    final source = identities[sourceId];
    if (!expense && !transfer) continue;
    if (source == null || (transfer && identities[row.cashTargetId] == null)) {
      return result(issue: '现金外流或转账缺少来源、去向持仓明细，收益调整待核对。');
    }
    if (source.liability || !source.type.isAmountBased) continue;
    if (!expense && identities[row.cashTargetId]?.liability != true) continue;
    final principal = transfer && !row.costMoved ? 0.0 : row.costMovedAmount;
    if (principal == null || !principal.isFinite || principal < 0) {
      return result(issue: '现金外流缺少有效的已记录本金，收益调整待核对。');
    }
    final gain = row.amount - principal;
    // Equal foreign-currency amounts can still carry an FX gain in CNY.
    if (row.currency.toUpperCase() != 'CNY') {
      return result(
        issue: '缺少 ${row.currency.toUpperCase()} 的历史折算依据，现金流水收益调整待核对。',
      );
    }
    if (gain == 0) continue;
    final issue = check(row);
    if (issue != null) return result(issue: issue);
    add(source.holdingId, gain);
  }

  for (final group in dividends.entries) {
    final id = group.key;
    final opening = before[id];
    final closing = after[id];
    if (beforeValues == null || closing == null) {
      return result(issue: '分红持仓缺少区间前后的成本明细，收益调整待核对。');
    }
    var capitalChange = 0.0;
    var hasOpeningBuy = false;
    for (final row in interval.where((row) => row.holdingId == id)) {
      if (row.type != 'buy' && row.type != 'sell') continue;
      final issue = check(row);
      if (issue != null) return result(issue: issue);
      final double? principal;
      if (row.type == 'buy') {
        principal = row.cashSourceId != null || row.internalMove
            ? row.costMovedAmount
            : row.amount;
        hasOpeningBuy = true;
      } else {
        principal = row.cashTargetId != null || row.internalMove
            ? row.costMovedAmount ?? replayedPrincipal[row.id]
            : row.externalSellPrincipal ?? replayedPrincipal[row.id];
      }
      if (principal == null || !principal.isFinite || principal < 0) {
        return result(issue: '分红期间的买卖缺少已记录本金，无法核对实际成本下降。');
      }
      capitalChange += row.type == 'buy' ? principal : -principal;
    }
    if (opening == null && !hasOpeningBuy) {
      return result(issue: '分红来源缺少期初成本或可核对的首次买入记录。');
    }
    final paid = group.value.fold(0.0, (sum, row) => sum + row.amount);
    final decrease = (opening?.cost ?? 0) + capitalChange - closing.cost;
    if (!decrease.isFinite ||
        decrease < -0.000001 ||
        decrease > paid + 0.000001) {
      return result(issue: '分红期间的持仓成本变化无法与已记录流水核对。');
    }
    // The holding's reduced cost already recognizes part of the dividend.
    // Attribute any excess payout to it too, while removing the whole cash
    // payout from the cash product's own investment return.
    add(id, paid - decrease.clamp(0.0, paid));
    for (final row in group.value) {
      add(row.cashTargetId!, -row.amount);
    }
  }
  return result();
}
