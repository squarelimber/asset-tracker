import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/domain/holding_cost.dart';

/// Pins the single source of truth for the "costPrice = 0 means never
/// recorded, fall back to the balance" rule.
///
/// `effectiveCostOf` delegates to `effectivePrincipal`, so the two readings
/// must always agree; if a caller ever re-types the ternary instead of
/// routing through here, the same number gets two readings and the
/// difference surfaces as a phantom profit. These tests are cheap insurance
/// against that drift.
void main() {
  test('记录了本金时，用记录的本金', () {
    expect(effectivePrincipal(9000, 10000), 9000);
  });

  test('本金为 0（未记录）时回退到余额，而不是当成真的 0 成本', () {
    expect(effectivePrincipal(0, 10000), 10000);
  });

  test('本金为负（历史脏数据）时同样回退到余额', () {
    expect(effectivePrincipal(-5, 10000), 10000);
  });

  test('显式记录的本金 0 是真的 0，不再回退到余额', () {
    // The whole point of the costRecorded flag: a user-entered 0 is a real
    // zero principal, so the entire balance is gain instead of being hidden.
    expect(effectivePrincipal(0, 10000, recorded: true), 0);
  });

  test('已记录的正数本金与未记录标记无关', () {
    // A positive cost is authoritative on its own; the flag only matters at 0.
    expect(effectivePrincipal(9000, 10000, recorded: true), 9000);
    expect(effectivePrincipal(9000, 10000, recorded: false), 9000);
  });
}
