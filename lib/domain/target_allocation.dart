import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/enums.dart';
import '../data/asset_dao.dart';

/// Settings key under which the user's target allocation plan is persisted
/// (a JSON map of [AssetCategory.storageName] -> target percentage).
const String targetAllocationKey = 'target_allocation';

/// Sensible default plan when the user has not configured one yet. The five
/// main categories sum to 100; 房产/银行理财 default to 0 (set them in the
/// alerts page if you hold them).
const Map<AssetCategory, double> defaultTargetAllocation = {
  AssetCategory.equity: 40,
  AssetCategory.bond: 25,
  AssetCategory.cash: 20,
  AssetCategory.gold: 10,
  AssetCategory.commodity: 5,
};

/// Legacy persisted category keys (the pre-rename six-category plan) mapped
/// to today's categories. `其他` (other) has no meaningful split, so it is
/// dropped. A plan containing any legacy key replaces the defaults entirely
/// so `stock + fund` sum into `equity` instead of stacking on the default.
const Map<String, String?> _legacyCategoryKeys = {
  'stock': 'equity', // 股票 -> 权益
  'fund': 'equity', // 基金 -> 权益
  'crypto': 'commodity', // 加密货币 -> 商品
  'other': null, // 其他 -> dropped
};

/// Parse the persisted target-allocation JSON. Missing or malformed entries
/// fall back to [defaultTargetAllocation]; unknown categories are ignored.
Map<AssetCategory, double> parseTargetAllocation(String? raw) {
  if (raw == null || raw.isEmpty) return {...defaultTargetAllocation};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {...defaultTargetAllocation};
    final hasLegacy =
        decoded.keys.any((k) => _legacyCategoryKeys.containsKey(k.toString()));
    // A legacy plan is migrated wholesale (defaults are not mixed in);
    // a current-format plan overlays the defaults as before.
    final result = hasLegacy
        ? <AssetCategory, double>{}
        : <AssetCategory, double>{...defaultTargetAllocation};
    for (final entry in decoded.entries) {
      final v = double.tryParse(entry.value.toString());
      if (v == null || !v.isFinite) continue;
      final key = entry.key.toString();
      // Legacy 'other' has no meaningful split: drop it.
      if (_legacyCategoryKeys.containsKey(key) &&
          _legacyCategoryKeys[key] == null) {
        continue;
      }
      final mapped = _legacyCategoryKeys[key] ?? key;
      final category = _categoryByStorage(mapped);
      // Unknown keys are ignored (documented behavior) — never let them
      // land on an arbitrary category via a fallback.
      if (category == null) continue;
      if (hasLegacy) {
        // Legacy keys can land twice on one category (股票 + 基金 -> 权益):
        // sum them onto the empty migration result.
        result[category] = (result[category] ?? 0) + v;
      } else {
        // Current format overlays the defaults.
        result[category] = v;
      }
    }
    return result;
  } catch (_) {
    // Corrupt payload: keep the defaults rather than failing the page.
    return {...defaultTargetAllocation};
  }
}

/// Exact storage-name lookup (no fallback): null for unknown keys.
AssetCategory? _categoryByStorage(String storageName) {
  for (final c in AssetCategory.values) {
    if (c.storageName == storageName) return c;
  }
  return null;
}

/// Rounds each category to one decimal and, when the total exceeds 100%,
/// trims the overflow off the largest category first. Slider fractions
/// (divisions over a dynamic cap) plus rounding used to be able to persist
/// e.g. 101%, which the editor then permanently rejected on load.
Map<AssetCategory, double> normalizeTargetAllocation(
  Map<AssetCategory, double> plan,
) {
  final out = <AssetCategory, double>{
    for (final e in plan.entries)
      e.key: double.parse(e.value.clamp(0.0, 100.0).toStringAsFixed(1)),
  };
  var total = out.values.fold(0.0, (a, b) => a + b);
  while (total > 100.0 + 1e-9) {
    AssetCategory? biggest;
    for (final e in out.entries) {
      if (e.value > 0 && (biggest == null || e.value > out[biggest]!)) {
        biggest = e.key;
      }
    }
    if (biggest == null) break;
    final reduced = double.parse(
      (out[biggest]! - 0.1).clamp(0.0, double.infinity).toStringAsFixed(1),
    );
    out[biggest] = reduced;
    total = out.values.fold(0.0, (a, b) => a + b);
  }
  return out;
}

/// Serialize a target-allocation plan to the persisted JSON form (one
/// decimal per category — slider steps are fractions, not integers).
String encodeTargetAllocation(Map<AssetCategory, double> plan) {
  final map = {
    for (final entry in plan.entries)
      entry.key.storageName:
          double.parse(entry.value.toStringAsFixed(1)),
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
/// The plan is normalized (≤100%, one decimal) before writing.
Future<void> saveTargetAllocation(
  AssetDao dao,
  Map<AssetCategory, double> plan,
) async {
  await dao.setSetting(
    targetAllocationKey,
    encodeTargetAllocation(normalizeTargetAllocation(plan)),
  );
}
