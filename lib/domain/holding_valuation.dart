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
  });

  final int holdingId;
  final String name;
  final AssetType type;
  final double value;
  final double cost;
  final bool liability;
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
      if (!value.isFinite || !cost.isFinite || !ids.add(item['id'] as int)) {
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
    if ((assets - debt - snapshot.totalValue).abs() > 0.000001 ||
        (cost - snapshot.totalCost).abs() > 0.000001 ||
        (debt - snapshot.liabilities).abs() > 0.000001) {
      return null;
    }
    return values;
  } catch (_) {
    return null;
  }
}
