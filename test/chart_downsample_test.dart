import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/domain/chart_downsample.dart';

List<ChartPoint> _sine(int n) => [
      for (var i = 0; i < n; i++)
        (x: i.toDouble(), y: 10 * math.sin(i * 0.35)),
    ];

void main() {
  final ds = const ChartDownsample();

  test('short series returned unchanged', () {
    final pts = _sine(240);
    expect(identical(ds.downsample(pts), pts), isTrue);
    expect(ds.downsample(_sine(10), target: 240), hasLength(10));
  });

  test('long series reduced to at most target points', () {
    final pts = _sine(1500);
    final out = ds.downsample(pts, target: 240);
    expect(out.length, lessThanOrEqualTo(240));
    expect(out.length, greaterThan(100));
  });

  test('x values stay sorted and are a subset of the input', () {
    final pts = _sine(1500);
    final out = ds.downsample(pts, target: 240);
    for (var i = 1; i < out.length; i++) {
      expect(out[i].x, greaterThan(out[i - 1].x));
    }
    final inputX = pts.map((p) => p.x).toSet();
    for (final p in out) {
      expect(inputX.contains(p.x), isTrue, reason: 'x ${p.x} not from input');
    }
  });

  test('first and last points are preserved', () {
    final pts = _sine(1500);
    final out = ds.downsample(pts, target: 240);
    expect(out.first, pts.first);
    expect(out.last, pts.last);
  });

  test('extremes of each bucket are kept (envelope preserved)', () {
    // One sharp spike in the middle of an otherwise flat series.
    final pts = <ChartPoint>[
      for (var i = 0; i < 1000; i++) (x: i.toDouble(), y: 0.0),
    ];
    pts[500] = (x: 500.0, y: 100.0);
    final out = ds.downsample(pts, target: 240);
    expect(out.any((p) => p.y == 100.0), isTrue,
        reason: 'the spike must survive downsampling');
  });

  test('monotonic ramp keeps endpoints and stays within range', () {
    final pts = <ChartPoint>[
      for (var i = 0; i < 2000; i++) (x: i.toDouble(), y: i.toDouble()),
    ];
    final out = ds.downsample(pts, target: 240);
    expect(out.first, pts.first);
    expect(out.last, pts.last);
    for (final p in out) {
      expect(p.y, inInclusiveRange(0.0, 1999.0));
    }
  });
}
