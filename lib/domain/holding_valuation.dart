import 'dart:convert';

import '../core/enums.dart';
import '../data/database.dart';

/// The holding values used to produce a snapshot, not a later revaluation.
class DayHoldingValue {
  const DayHoldingValue({
    required this.holdingId,
    required this.name,
    required this.type,
    required this.value,
    required this.cost,
    required this.liability,
    this.realizedProfit = 0,
    this.profitAdjustment = 0,
  });

  final int holdingId;
  final String name;
  final AssetType type;
  final double value;
  final double cost;
  final bool liability;
  final double realizedProfit;
  final double profitAdjustment;

  DayHoldingValue withRealizedProfit(double profit) => DayHoldingValue(
    holdingId: holdingId,
    name: name,
    type: type,
    value: value,
    cost: cost,
    liability: liability,
    realizedProfit: profit,
    profitAdjustment: profitAdjustment,
  );

  DayHoldingValue withProfitAdjustment(double adjustment) => DayHoldingValue(
    holdingId: holdingId,
    name: name,
    type: type,
    value: value,
    cost: cost,
    liability: liability,
    realizedProfit: realizedProfit,
    profitAdjustment: adjustment,
  );
}

String encodeHoldingValues(List<DayHoldingValue> values) => jsonEncode([
  for (final h in values)
    {
      'id': h.holdingId,
      'name': h.name,
      'type': h.type.storageName,
      'value': h.value,
      'cost': h.cost,
      'liability': h.liability,
      if (h.realizedProfit != 0) 'realizedProfit': h.realizedProfit,
      if (h.profitAdjustment != 0) 'profitAdjustment': h.profitAdjustment,
    },
]);

/// Old or invalid payloads remain unavailable rather than being presented as
/// a complete explanation. Validate all three totals, including liabilities.
List<DayHoldingValue>? snapshotHoldingValues(SnapshotRow snapshot) {
  final raw = snapshot.holdingValues;
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    final values = <DayHoldingValue>[];
    final ids = <int>{};
    for (final item in decoded) {
      if (item is! Map ||
          item['id'] is! int ||
          item['name'] is! String ||
          item['type'] is! String ||
          item['value'] is! num ||
          item['cost'] is! num ||
          item['liability'] is! bool) {
        return null;
      }
      final value = (item['value'] as num).toDouble();
      final cost = (item['cost'] as num).toDouble();
      final realized = (item['realizedProfit'] as num?)?.toDouble() ?? 0;
      final adjustment = (item['profitAdjustment'] as num?)?.toDouble() ?? 0;
      if (!value.isFinite ||
          !cost.isFinite ||
          !realized.isFinite ||
          !adjustment.isFinite ||
          !ids.add(item['id'] as int)) {
        return null;
      }
      final type = AssetType.values
          .where((t) => t.storageName == item['type'])
          .firstOrNull;
      if (type == null || (type == AssetType.liability) != item['liability']) {
        return null;
      }
      values.add(
        DayHoldingValue(
          holdingId: item['id'] as int,
          name: item['name'] as String,
          type: type,
          value: value,
          cost: cost,
          liability: item['liability'] as bool,
          realizedProfit: realized,
          profitAdjustment: adjustment,
        ),
      );
    }
    final assets = values
        .where((v) => !v.liability)
        .fold(0.0, (s, v) => s + v.value);
    final cost = values
        .where((v) => !v.liability)
        .fold(0.0, (s, v) => s + v.cost);
    final debt = values
        .where((v) => v.liability)
        .fold(0.0, (s, v) => s + v.value);
    final realized = values.fold(0.0, (s, v) => s + v.realizedProfit);
    final adjustment = values.fold(0.0, (s, v) => s + v.profitAdjustment);
    if ((assets - debt - snapshot.totalValue).abs() > 0.000001 ||
        (cost - snapshot.totalCost).abs() > 0.000001 ||
        (debt - snapshot.liabilities).abs() > 0.000001 ||
        (realized - (snapshot.realizedProfit ?? 0)).abs() > 0.000001 ||
        (adjustment - (snapshot.profitAdjustment ?? 0)).abs() > 0.000001) {
      return null;
    }
    return values;
  } catch (_) {
    return null;
  }
}
