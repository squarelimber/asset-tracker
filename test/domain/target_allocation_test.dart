import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/domain/target_allocation.dart';

void main() {
  group('parseTargetAllocation', () {
    test('null or empty falls back to defaults', () {
      final plan = parseTargetAllocation(null);
      expect(plan[AssetCategory.equity], 40);
      expect(plan[AssetCategory.bond], 25);
      expect(plan[AssetCategory.cash], 20);
      expect(plan[AssetCategory.gold], 10);
      expect(plan[AssetCategory.commodity], 5);
      expect(plan[AssetCategory.property], isNull);
      expect(plan[AssetCategory.bankWealth], isNull);
    });

    test('current-format JSON overlays the defaults', () {
      final plan = parseTargetAllocation(
        '{"equity":50,"bond":20,"cash":30}',
      );
      expect(plan[AssetCategory.equity], 50);
      expect(plan[AssetCategory.bond], 20);
      expect(plan[AssetCategory.cash], 30);
      expect(plan[AssetCategory.gold], 10); // untouched default
    });

    test('legacy plan migrates stock+fund into equity and drops other', () {
      // Pre-rename plan: 股票 40 + 基金 30 land in 权益 (70), 其他 5 dropped,
      // and the defaults are NOT mixed in (equity 70, not 70 + default 40).
      final plan = parseTargetAllocation(
        '{"stock":40,"fund":30,"gold":10,"bond":10,"cash":10,"other":5}',
      );
      expect(plan[AssetCategory.equity], 70);
      expect(plan[AssetCategory.gold], 10);
      expect(plan[AssetCategory.bond], 10);
      expect(plan[AssetCategory.cash], 10);
      expect(plan.containsKey(AssetCategory.commodity), isFalse);
    });

    test('legacy crypto maps to commodity', () {
      final plan = parseTargetAllocation('{"crypto":8}');
      expect(plan[AssetCategory.commodity], 8);
    });

    test('corrupt JSON falls back to defaults', () {
      final plan = parseTargetAllocation('not-json{');
      expect(plan[AssetCategory.equity], 40);
    });
  });

  group('encodeTargetAllocation', () {
    test('round-trips through parse', () {
      const plan = {
        AssetCategory.equity: 40.0,
        AssetCategory.bond: 25.0,
        AssetCategory.cash: 20.0,
        AssetCategory.gold: 10.0,
        AssetCategory.commodity: 5.0,
      };
      final parsed = parseTargetAllocation(encodeTargetAllocation(plan));
      expect(parsed, plan);
    });
  });
}