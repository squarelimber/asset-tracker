import 'dart:math' as math;

/// A set of "nice" axis ticks: a rounded step (1/2/5 × 10ⁿ) and the aligned
/// tick values that cover a [min]..[max] range.
///
/// Used so chart axis labels are always evenly spaced, human-friendly numbers
/// (e.g. 0, 1, 2, 3 or 3.0, 3.1, 3.2) instead of the raw min/max values that
/// fl_chart force-includes by default — which crowd together and overlap when
/// the data range is small.
class NiceTicks {
  const NiceTicks(this.step, this.ticks);

  /// Rounded step between consecutive ticks.
  final double step;

  /// Tick values, aligned to [step], covering the requested range.
  final List<double> ticks;

  /// Decimal places needed to render [step] without losing precision.
  int get decimals {
    if (step >= 1) return 0;
    if (step >= 0.1) return 1;
    return 2;
  }
}

/// Builds [NiceTicks] for a value range.
abstract final class NiceAxis {
  /// Returns ticks covering [min]..[max] with roughly [targetCount] steps.
  ///
  /// The step is rounded to the nearest 1/2/5 × 10ⁿ so labels read cleanly,
  /// and the tick sequence is aligned to that step (starting at
  /// `floor(min/step)*step`) so it always includes values just outside the
  /// raw range — the axis is then clamped to the first/last tick.
  static NiceTicks ticks(double min, double max, {int targetCount = 4}) {
    if (min == max) {
      // Flat series: a single tick at the value (0 when the value is 0).
      final v = min == 0 ? 0.0 : min;
      return NiceTicks(1, [v]);
    }
    final span = max - min;
    final step = _niceStep(span / targetCount);
    final decimals = _decimalsFor(step);
    final first = (min / step).floorToDouble() * step;
    final last = (max / step).ceilToDouble() * step;
    final count = ((last - first) / step).round() + 1;
    final raw = List<double>.generate(count, (i) => first + i * step);
    // Strip float noise (e.g. 3.0000000000000004) by rounding to [decimals].
    final clean = [
      for (final t in raw) double.parse(t.toStringAsFixed(decimals)),
    ];
    return NiceTicks(step, clean);
  }

  static double _niceStep(double raw) {
    if (raw <= 0) return 1;
    final exp = (math.log(raw) / math.ln10).floor();
    final base = math.pow(10, exp).toDouble();
    final frac = raw / base;
    final nice = frac <= 1 ? 1.0 : (frac <= 2 ? 2.0 : (frac <= 5 ? 5.0 : 10.0));
    return nice * base;
  }

  static int _decimalsFor(double step) {
    if (step >= 1) return 0;
    if (step >= 0.1) return 1;
    return 2;
  }
}
