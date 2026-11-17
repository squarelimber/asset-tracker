import 'package:asset_tracker/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('heat intensity increases with absolute magnitude on either side of zero', () {
    final smallLoss = T.heat(-10, -100, 60);
    final largeLoss = T.heat(-100, -100, 60);
    final smallGain = T.heat(10, -100, 60);
    final largeGain = T.heat(60, -100, 60);

    expect(largeLoss.a, greaterThan(smallLoss.a));
    expect(largeGain.a, greaterThan(smallGain.a));
    expect(smallLoss.a, closeTo(smallGain.a, 0.0001));
    expect(smallLoss.withValues(alpha: 1), T.down);
    expect(smallGain.withValues(alpha: 1), T.up);
    expect(T.heat(0, -100, 60), Colors.transparent);
  });

  test('single-value ranges still show the correct gain or loss', () {
    expect(T.heat(-10, -10, -10).a, greaterThan(0));
    expect(T.heat(10, 10, 10).a, greaterThan(0));
    expect(T.heat(0, 0, 0), Colors.transparent);
  });

  test('light text remains readable on the strongest gain and loss fills', () {
    for (final background in [T.bg, T.surface, T.surface2]) {
      for (final value in [-100.0, 100.0]) {
        final fill = Color.alphaBlend(T.heat(value, -100, 100), background);
        final contrast = (T.text1.computeLuminance() + 0.05) /
            (fill.computeLuminance() + 0.05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
    }
  });
}
