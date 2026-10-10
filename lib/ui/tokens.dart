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

  /// Faint text / disabled. Bright enough for WCAG AA (≥4.5:1) on [bg].
  static const Color text3 = Color(0xFF768390);
  static const Color up = Color(0xFFF85149);
  static const Color down = Color(0xFF3FB950);
  static const Color accent = Color(0xFF58A6FF);

  /// 趋势曲线色：青 → 紫横向渐变（铺满整幅绘图区）。
  ///
  /// 单色试过两版都不理想：白偏蓝在深色面板上发灰，accent 蓝又被网格的
  /// 灰调淹没。横向渐变让曲线左青右紫、两端都保持饱和度，既在全局蓝色系
  /// 里，又不会跟涨跌语义色（红/绿）撞车。注意**纯色紫刻意不用作主线**：
  /// 指数对比里的「上证50」就是紫线。
  ///
  /// [trendFrom] 同时也是曲线下方填充与末端脉冲点的基色（同一条曲线只
  /// 认一个色族）；[trendTo] 是末端脉冲点的取色（曲线右端落在渐变末尾）。
  static const Color trendFrom = Color(0xFF5EE0FF);
  static const Color trendTo = Color(0xFFB48CFF);

  /// 曲线本体（横向青→紫）。
  static const LinearGradient trendGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [trendFrom, trendTo],
  );

  /// 曲线发光层：同渐变、低透明度，作为更宽的底描边叠在曲线下面。
  static final LinearGradient trendGlowGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      trendFrom.withValues(alpha: 0.12),
      trendTo.withValues(alpha: 0.12),
    ],
  );

  /// 曲线下方填充：同一横向渐变、整体压低透明度（纵向渐隐由 fl_chart 的
  /// 面积矩形裁剪表现，这里只控制强弱）。
  static final LinearGradient trendAreaGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      trendFrom.withValues(alpha: 0.18),
      trendTo.withValues(alpha: 0.08),
    ],
  );

  static const Color warning = Color(0xFFD29922);

  static const double rCard = 8;
  static const double rInput = 6;
  static const double rPill = 999;

  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;

  /// Monospace style for all numeric values (terminal look).
  ///
  /// `monospace` resolves to the platform mono family (Droid Sans Mono on
  /// Android, the CSS generic on web); the fallback chain covers Windows
  /// (Consolas) and iOS (Menlo), where the bare name does not resolve.
  /// CJK glyphs fall back per-glyph to the system font automatically.
  static TextStyle mono({
    double size = 14,
    Color? color,
    FontWeight weight = FontWeight.w400,
  }) => TextStyle(
    fontSize: size,
    color: color ?? text1,
    fontWeight: weight,
    fontFamily: 'monospace',
    fontFamilyFallback: const [
      'Consolas',
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
