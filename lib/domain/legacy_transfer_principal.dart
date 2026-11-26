import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;

import '../data/database.dart';
import 'daily_earnings.dart' show snapshotCalendarDate;
import 'holding_valuation.dart';
import 'transaction_identity.dart';

/// Calculation-only compatibility for old ledgers. A value is recovered only
/// when recorded holding costs uniquely determine it. This does not mutate
/// transactions or claim to reconstruct a broker's original tax cost basis.
List<TransactionRow> resolveLegacyTransferPrincipal(
  List<SnapshotRow> snapshots,
  List<TransactionRow> transactions,
) {
  if (!transactions.any(
    (t) =>
        t.costMovedAmount == null ||
        (isExternalSale(t) && t.externalSellPrincipal == null),
  )) {
    return transactions;
  }
  final ordered = snapshots.where((s) => s.currency == 'CNY').toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  final byDay = <String, List<TransactionRow>>{};
  for (final row in transactions) {
    final day = row.occurredAt.toLocal().toIso8601String().substring(0, 10);
    (byDay[day] ??= []).add(row);
  }
  final replacements = <int, TransactionRow>{};
  for (var i = 1; i < ordered.length; i++) {
    final previous = ordered[i - 1];
    final current = ordered[i];
    // A multi-day gap does not document the intervening transaction costs.
    final beforeDate = snapshotCalendarDate(previous.date);
    final afterDate = snapshotCalendarDate(current.date);
    if (beforeDate == null ||
        afterDate == null ||
        afterDate.difference(beforeDate).inDays != 1) {
      continue;
    }
    final rows = [...?byDay[current.date]]
      ..sort((a, b) {
        final time = a.occurredAt.compareTo(b.occurredAt);
        return time == 0 ? compareTransactionEntryOrder(a, b) : time;
      });
    if (rows.isEmpty) continue;
    replacements.addAll(_recover(previous, current, rows));
  }
  if (replacements.isEmpty) return transactions;
  return [for (final row in transactions) replacements[row.id] ?? row];
}

class _CostFlow {
  const _CostFlow(this.row, this.effects, this.principal, this.field);
  final TransactionRow row;
  final Map<int, double> effects;
  final double? principal;
  final String field;
}

bool _near(double a, double b) =>
    a.isFinite &&
    b.isFinite &&
    (a - b).abs() <= math.max(0.000001, math.max(a.abs(), b.abs()) * 1e-10);

Map<int, TransactionRow> _recover(
  SnapshotRow previous,
  SnapshotRow current,
  List<TransactionRow> rows,
) {
  final beforeValues = snapshotHoldingValues(previous);
  final afterValues = snapshotHoldingValues(current);
  if (beforeValues == null || afterValues == null) return {};
  final before = {for (final v in beforeValues) v.holdingId: v};
  final after = {for (final v in afterValues) v.holdingId: v};
  if (before.keys.any(
    (id) =>
        after.containsKey(id) &&
        (before[id]!.type != after[id]!.type ||
            before[id]!.liability != after[id]!.liability),
  )) {
    return {};
  }
  final identities = {...before, ...after};
  bool asset(int? id) => identities[id] != null && !identities[id]!.liability;
  bool cash(int? id) => asset(id) && identities[id]!.type.isAmountBased;
  final flows = <_CostFlow>[];
  for (final row in rows) {
    if (row.currency.toUpperCase() != 'CNY' ||
        row.historyUpdatedAt.isAfter(current.createdAt) ||
        !row.amount.isFinite ||
        row.amount < 0) {
      return {};
    }
    final id = row.holdingId;
    final source = row.cashSourceId;
    final target = row.cashTargetId;
    switch (row.type) {
      case 'income':
        if (!cash(target)) return {};
        flows.add(_CostFlow(row, {target!: 1}, row.costMovedAmount, 'cost'));
      case 'expense':
        if (!cash(target)) return {};
        flows.add(_CostFlow(row, {target!: -1}, row.costMovedAmount, 'cost'));
      case 'transfer_in' || 'transfer_out':
        if (identities[source] == null ||
            identities[target] == null ||
            !(cash(source) || identities[source]!.liability) ||
            !(cash(target) || identities[target]!.liability)) {
          return {};
        }
        final effects = <int, double>{};
        if (asset(source)) effects[source!] = -1;
        if (asset(target)) {
          effects.update(target!, (v) => v + 1, ifAbsent: () => 1);
        }
        if (effects.isEmpty) continue;
        flows.add(
          _CostFlow(
            row,
            effects,
            row.costMoved ? row.costMovedAmount : 0,
            'cost',
          ),
        );
      case 'buy':
        if (!asset(id)) return {};
        if (!cash(id) &&
            (row.quantity == null ||
                !row.quantity!.isFinite ||
                row.quantity! <= 0)) {
          return {};
        }
        if (source != null) {
          if (!cash(source) || source == id) return {};
          flows.add(
            _CostFlow(row, {source: -1, id!: 1}, row.costMovedAmount, 'cost'),
          );
        } else {
          flows.add(
            _CostFlow(
              row,
              {id!: 1},
              row.internalMove ? row.costMovedAmount : row.amount,
              row.internalMove ? 'cost' : 'fixed',
            ),
          );
        }
      case 'sell':
        if (!asset(id)) return {};
        if (!cash(id) &&
            (row.quantity == null ||
                !row.quantity!.isFinite ||
                row.quantity! <= 0)) {
          return {};
        }
        if (target != null) {
          if (!cash(target) || target == id) return {};
          flows.add(
            _CostFlow(row, {id!: -1, target: 1}, row.costMovedAmount, 'cost'),
          );
        } else if (row.internalMove || cash(id)) {
          flows.add(_CostFlow(row, {id!: -1}, row.costMovedAmount, 'cost'));
        } else {
          flows.add(
            _CostFlow(row, {id!: -1}, row.externalSellPrincipal, 'external'),
          );
        }
      case 'consume' || 'split':
        continue;
      // A dividend can clamp cost to zero. Do not invent an ordering-dependent
      // reduction while trying to solve another missing field on that day.
      default:
        return {};
    }
  }
  final unknown = flows
      .where((f) => f.principal == null && f.field != 'fixed')
      .toList();
  if (unknown.isEmpty || unknown.any((f) => f.effects.isEmpty)) return {};
  if (flows.any(
    (f) => f.principal != null && (!f.principal!.isFinite || f.principal! < 0),
  )) {
    return {};
  }
  final index = {for (var i = 0; i < unknown.length; i++) unknown[i].row.id: i};
  final matrix = <List<double>>[];
  final touched = {for (final flow in flows) ...flow.effects.keys};
  for (final entry in identities.entries.where(
    (e) => touched.contains(e.key),
  )) {
    if (entry.value.liability) continue;
    final id = entry.key;
    if ((before[id]?.cost ?? 0) < 0 || (after[id]?.cost ?? 0) < 0) return {};
    final equation = List<double>.filled(unknown.length + 1, 0);
    equation.last = (after[id]?.cost ?? 0) - (before[id]?.cost ?? 0);
    for (final flow in flows) {
      final coefficient = flow.effects[id] ?? 0;
      if (flow.principal != null) {
        equation.last -= coefficient * flow.principal!;
      } else {
        equation[index[flow.row.id]!] += coefficient;
      }
    }
    matrix.add(equation);
  }
  void equalPrincipals(
    _CostFlow a,
    _CostFlow b,
    double aFactor,
    double bFactor,
  ) {
    final equation = List<double>.filled(unknown.length + 1, 0);
    for (final term in [(a, aFactor), (b, -bFactor)]) {
      final flow = term.$1;
      if (flow.principal != null) {
        equation.last -= term.$2 * flow.principal!;
      } else {
        equation[index[flow.row.id]!] += term.$2;
      }
    }
    matrix.add(equation);
  }

  // Two partial sales of the same share position have the same unit cost
  // only when no buy, split or dividend changed that position during the day.
  for (final id in identities.keys) {
    if (!asset(id) || cash(id)) continue;
    final events = rows.where((r) => r.holdingId == id).toList();
    if (events.any((r) => r.type != 'sell') ||
        rows.any((r) => r.cashSourceId == id || r.cashTargetId == id)) {
      continue;
    }
    final sales = flows
        .where((f) => f.row.holdingId == id && f.row.type == 'sell')
        .toList();
    if (sales.length < 2 ||
        sales.any(
          (f) =>
              f.row.quantity == null ||
              !f.row.quantity!.isFinite ||
              f.row.quantity! <= 0,
        )) {
      continue;
    }
    for (final other in sales.skip(1)) {
      equalPrincipals(
        sales.first,
        other,
        other.row.quantity!,
        sales.first.row.quantity!,
      );
    }
  }
  for (final flow in flows.where((f) => isRedemptionLeg(f.row))) {
    final matches = flows
        .where(
          (other) =>
              other.row.id != flow.row.id &&
              isRedemptionLeg(other.row) &&
              other.row.type != flow.row.type &&
              other.row.holdingId != flow.row.holdingId &&
              other.row.amount == flow.row.amount &&
              (flow.row.redemptionGroup != null
                  ? flow.row.redemptionGroup == other.row.redemptionGroup
                  : other.row.redemptionGroup == null &&
                        flow.row.occurredAt.isAtSameMomentAs(
                          other.row.occurredAt,
                        )),
        )
        .toList();
    if (matches.length != 1) return {};
    equalPrincipals(flow, matches.single, 1, 1);
  }
  final solution = _uniqueSolution(matrix, unknown.length);
  if (solution == null || solution.any((v) => !v.isFinite || v < -0.000001)) {
    return {};
  }
  // Replay the costs in transaction order as an additional feasibility check.
  final costs = {for (final id in identities.keys) id: before[id]?.cost ?? 0.0};
  for (final flow in flows) {
    final principal = flow.principal ?? solution[index[flow.row.id]!];
    for (final effect in flow.effects.entries) {
      costs[effect.key] = costs[effect.key]! + effect.value * principal;
      if (costs[effect.key]! < -0.000001) return {};
    }
  }
  if (touched
      .where(asset)
      .any((id) => !_near(costs[id]!, after[id]?.cost ?? 0))) {
    return {};
  }
  return {
    for (var i = 0; i < unknown.length; i++)
      unknown[i].row.id: unknown[i].field == 'external'
          ? unknown[i].row.copyWith(
              externalSellPrincipal: Value(math.max(0, solution[i])),
            )
          : unknown[i].row.copyWith(
              costMovedAmount: Value(math.max(0, solution[i])),
            ),
  };
}

List<double>? _uniqueSolution(List<List<double>> original, int count) {
  final matrix = [
    for (final row in original) [...row],
  ];
  var pivotRow = 0;
  final pivots = <int>[];
  for (var col = 0; col < count && pivotRow < matrix.length; col++) {
    var best = pivotRow;
    for (var r = pivotRow + 1; r < matrix.length; r++) {
      if (matrix[r][col].abs() > matrix[best][col].abs()) best = r;
    }
    if (matrix[best][col].abs() < 1e-10) continue;
    final temp = matrix[pivotRow];
    matrix[pivotRow] = matrix[best];
    matrix[best] = temp;
    final divisor = matrix[pivotRow][col];
    for (var j = col; j <= count; j++) {
      matrix[pivotRow][j] /= divisor;
    }
    for (var r = 0; r < matrix.length; r++) {
      if (r == pivotRow) continue;
      final factor = matrix[r][col];
      for (var j = col; j <= count; j++) {
        matrix[r][j] -= factor * matrix[pivotRow][j];
      }
    }
    pivots.add(col);
    pivotRow++;
  }
  if (matrix.any(
    (row) =>
        row.take(count).every((v) => v.abs() < 1e-8) &&
        row.last.abs() > 0.000001,
  )) {
    return null;
  }
  if (pivots.length != count) return null;
  final solution = List<double>.filled(count, 0);
  for (var r = 0; r < pivots.length; r++) {
    solution[pivots[r]] = matrix[r].last;
  }
  if (original.any(
    (row) => !_near(
      List.generate(
        count,
        (i) => row[i] * solution[i],
      ).fold(0.0, (a, b) => a + b),
      row.last,
    ),
  )) {
    return null;
  }
  return solution;
}
