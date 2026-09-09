import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/enums.dart';
import '../data/asset_dao.dart';

/// Settings key under which the user's target allocation plan is persisted
/// (a JSON map of [AssetCategory.storageName] -> target percentage).
const String targetAllocationKey = 'target_allocation';

/// Sensible default plan when the user has not configured one yet. The five
/// investable categories sum to 100; `其他` is intentionally omitted (0).
const Map<AssetCategory, double> defaultTargetAllocation = {
  AssetCategory.stock: 40,
  AssetCategory.fund: 30,
  AssetCategory.gold: 10,
  AssetCategory.bond: 10,
  AssetCategory.cash: 10,
};

/// Parse the persisted target-allocation JSON. Missing or malformed entries
/// fall back to [defaultTargetAllocation]; unknown categories are ignored.
Map<AssetCategory, double> parseTargetAllocation(String? raw) {
  final result = <AssetCategory, double>{...defaultTargetAllocation};
  if (raw == null || raw.isEmpty) return result;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return result;
    for (final entry in decoded.entries) {
      final category = AssetCategory.fromStorage(entry.key.toString());
      final v = double.tryParse(entry.value.toString());
      if (v != null && v.isFinite) result[category] = v;
    }
  } catch (_) {
    // Corrupt payload: keep the defaults rather than failing the page.
  }
  return result;
}

/// Serialize a target-allocation plan to the persisted JSON form.
String encodeTargetAllocation(Map<AssetCategory, double> plan) {
  final map = {
    for (final entry in plan.entries)
      entry.key.storageName: entry.value.roundToDouble(),
  };
  return jsonEncode(map);
}

/// Reactive read of the user's target allocation plan.
final targetAllocationProvider =
    FutureProvider<Map<AssetCategory, double>>((ref) async {
  final dao = ref.watch(daoProvider);
  final raw = await dao.getSetting(targetAllocationKey);
  return parseTargetAllocation(raw);
});

/// Persist a target-allocation plan. Callers invalidate
/// [targetAllocationProvider] afterwards so dependents refresh.
Future<void> saveTargetAllocation(
  AssetDao dao,
  Map<AssetCategory, double> plan,
) async {
  await dao.setSetting(targetAllocationKey, encodeTargetAllocation(plan));
}
