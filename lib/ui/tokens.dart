import 'package:flutter/material.dart';

/// Terminal design tokens (dark only).
class T {
  T._();

  static const Color bg = Color(0xFF131517);
  static const Color surface = Color(0xFF1B1E22);
  static const Color surface2 = Color(0xFF25292E);
  static const Color border = Color(0xFF3A4047);
  static const Color borderSoft = Color(0xFF2C3137);
  static const Color text1 = Color(0xFFE6E8EB);
  static const Color text2 = Color(0xFFADB3BB);

  /// Faint text / disabled. Bright enough for WCAG AA (≥4.5:1) on [bg].
  static const Color text3 = Color(0xFF8B929B);
  static const Color up = Color(0xFFE48282);
  static const Color down = Color(0xFF73B9A2);
  static const Color accent = Color(0xFFD5B276);

  /// Muted steel line for measurements; red/green is reserved for P&L.
  static const Color trendFrom = Color(0xFF9BAFC3);
  static const Color trendTo = trendFrom;
  static const LinearGradient trendGradient = LinearGradient(
    colors: [trendFrom, trendTo],
  );
  static final LinearGradient trendAreaGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [trendFrom.withValues(alpha: 0.10), trendFrom.withValues(alpha: 0)],
  );

  static const Color warning = Color(0xFFD29922);

  static const double rCard = 4;
  static const double rInput = 3;
  static const double rPill = 999;

  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;

  /// Monospace is reserved for financial measurements and instrument codes.
  /// Consolas is native on Windows; other platforms use their local mono font.
  static TextStyle mono({
    double size = 14,
    Color? color,
    FontWeight weight = FontWeight.w400,
  }) => TextStyle(
    fontSize: size,
    color: color ?? text1,
    fontWeight: weight,
    fontFamily: 'Consolas',
    fontFamilyFallback: const [
      'monospace',
      'Menlo',
      'Droid Sans Mono',
      'Courier New',
    ],
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  static TextStyle label({double size = 11, Color? color}) => TextStyle(
    fontSize: size,
    color: color ?? text2,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
  );

  /// Red for positive, green for negative (China convention).
  static Color changeColor(double value) =>
      value == 0 ? text2 : (value > 0 ? up : down);

  /// Heatmap fill for [value] within [min, max]; zero or degenerate range
  /// is transparent.
  static Color heat(double value, double min, double max) {
    if (value == 0 || max <= min) return Colors.transparent;
    final t = ((value - min) / (max - min)).clamp(0.0, 1.0);
    return (value >= 0 ? up : down).withValues(alpha: 0.12 + 0.55 * t);
  }
}
