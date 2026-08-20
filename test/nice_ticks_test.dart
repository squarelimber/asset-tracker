import 'dart:math' as math;

import 'package:asset_tracker/domain/nice_ticks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NiceAxis.ticks', () {
    test('small range gets a 0.1 step with 1 decimal', () {
      // ~0.3% span (the "3% vs 3.08%" overlap case).
      final t = NiceAxis.ticks(2.937, 3.237);
      expect(t.step, 0.1);
      expect(t.decimals, 1);
      expect(t.ticks, [2.9, 3.0, 3.1, 3.2, 3.3]);
    });

    test('ticks cover the raw range', () {
      final t = NiceAxis.ticks(2.937, 3.237);
      expect(t.ticks.first, lessThanOrEqualTo(2.937));
      expect(t.ticks.last, greaterThanOrEqualTo(3.237));
    });

    test('large range uses a 20 step with 0 decimals', () {
      // raw step 52/4 = 13 -> rounds to 20 (1/2/5 × 10^n).
      final t = NiceAxis.ticks(0.0, 52);
      expect(t.step, 20);
      expect(t.decimals, 0);
      expect(t.ticks, [0, 20, 40, 60]);
    });

    test('crosses zero with aligned negative ticks', () {
      // raw step 6/4 = 1.5 -> rounds to 2.
      final t = NiceAxis.ticks(-2.5, 3.5);
      expect(t.step, 2);
      expect(t.decimals, 0);
      expect(t.ticks, [-4, -2, 0, 2, 4]);
    });

    test('very small range falls back to 2 decimals', () {
      final t = NiceAxis.ticks(3.0, 3.04);
      expect(t.decimals, 2);
      expect(t.ticks.first, lessThanOrEqualTo(3.0));
      expect(t.ticks.last, greaterThanOrEqualTo(3.04));
      // All ticks are distinct (no overlap).
      expect(t.ticks.toSet().length, t.ticks.length);
    });

    test('flat range returns a single tick', () {
      expect(NiceAxis.ticks(5, 5).ticks, [5]);
      expect(NiceAxis.ticks(0, 0).ticks, [0]);
    });

    test('step is always a 1/2/5 × 10^n number', () {
      for (final span in [0.3, 1.7, 4.2, 9.9, 23.0, 87.0, 400.0]) {
        final t = NiceAxis.ticks(0.0, span);
        final exp = (math.log(t.step) / math.log(10.0)).floor();
        final mantissa = (t.step / math.pow(10.0, exp).toDouble()).round();
        expect([1, 2, 5], contains(mantissa), reason: 'step=${t.step}');
      }
    });

    test('tick values are distinct and ascending', () {
      for (final pair in [
        [0.0, 0.3],
        [-5.2, 5.2],
        [100.0, 199.0],
        [3.003, 3.412],
      ]) {
        final t = NiceAxis.ticks(pair[0], pair[1]);
        expect(t.ticks.toSet().length, t.ticks.length);
        for (var i = 1; i < t.ticks.length; i++) {
          expect(t.ticks[i], greaterThan(t.ticks[i - 1]));
        }
      }
    });
  });
}
