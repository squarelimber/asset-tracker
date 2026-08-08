import 'package:flutter/material.dart';

/// Design tokens: modern minimal financial style.
/// Up = red, Down = green (China market convention).
class AppColors {
  AppColors._();

  static const Color primary = Color(0xFF1E3A5F); // deep navy
  static const Color up = Color(0xFFE64545); // gain red
  static const Color down = Color(0xFF00B578); // loss green
  static const Color warning = Color(0xFFFF9500);
  static const Color background = Color(0xFFF6F7F9);
  static const Color card = Colors.white;
}

class AppTheme {
  AppTheme._();

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? const Color(0xFF121417) : AppColors.background,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: isDark ? const Color(0xFF1C1F23) : AppColors.card,
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: isDark ? const Color(0xFF121417) : AppColors.background,
      ),
      navigationBarTheme: const NavigationBarThemeData(),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        isDense: true,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 0.5,
      ),
      textTheme: TextTheme(
        // Large figures for money amounts.
        headlineMedium: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        titleLarge: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Up/down color helper honoring theme brightness.
extension UpDownColor on BuildContext {
  Color upColor() => AppColors.up;
  Color downColor() => AppColors.down;

  /// Red for positive change, green for negative (China convention).
  Color changeColor(double value) => value >= 0 ? AppColors.up : AppColors.down;
}
