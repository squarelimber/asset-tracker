import 'package:flutter/material.dart';

/// Terminal design tokens (dark only).
class T {
  T._();

  static const Color bg = Color(0xFF0A0C0F);
  static const Color surface = Color(0xFF12151A);
  static const Color surface2 = Color(0xFF1A1F26);
  static const Color border = Color(0xFF262B33);
  static const Color borderSoft = Color(0xFF1C2128);
  static const Color text1 = Color(0xFFE6EDF3);
  static const Color text2 = Color(0xFF8B949E);
  static const Color text3 = Color(0xFF545D68);
  static const Color up = Color(0xFFF85149);
  static const Color down = Color(0xFF3FB950);
  static const Color accent = Color(0xFF58A6FF);
  static const Color warning = Color(0xFFD29922);

  static const double rCard = 8;
  static const double rInput = 6;
  static const double rPill = 999;

  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;

  static TextStyle mono({
    double size = 14,
    Color? color,
    FontWeight weight = FontWeight.w400,
  }) =>
      TextStyle(
        fontSize: size,
        color: color ?? text1,
        fontWeight: weight,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static TextStyle label({double size = 11, Color? color}) => TextStyle(
        fontSize: size,
        color: color ?? text2,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.4,
      );

  /// Red for positive, green for negative (China convention).
  static Color changeColor(double value) => value >= 0 ? up : down;

  /// Heatmap fill for [value] within [min, max]; zero or degenerate range
  /// is transparent.
  static Color heat(double value, double min, double max) {
    if (value == 0 || max <= min) return Colors.transparent;
    final t = ((value - min) / (max - min)).clamp(0.0, 1.0);
    return (value >= 0 ? up : down).withValues(alpha: 0.12 + 0.55 * t);
  }
}
