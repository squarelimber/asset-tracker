import 'package:flutter/material.dart';

import '../ui/tokens.dart';

class AppTheme {
  AppTheme._();

  static ThemeData dark() {
    final scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: T.accent,
      onPrimary: Colors.black,
      secondary: T.accent,
      onSecondary: Colors.black,
      surface: T.surface,
      onSurface: T.text1,
      error: T.up,
      onError: Colors.black,
      outline: T.border,
      outlineVariant: T.borderSoft,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: T.bg,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: T.bg,
        foregroundColor: T.text1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rCard),
          side: const BorderSide(color: T.border),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: T.surface,
        indicatorColor: T.surface2,
        iconTheme: WidgetStatePropertyAll(IconThemeData(color: T.text2)),
        labelTextStyle: WidgetStatePropertyAll(T.label(size: 11)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: T.surface,
        indicatorColor: T.surface2,
      ),
      dividerTheme: const DividerThemeData(color: T.border, thickness: 1),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: T.surface2,
        contentTextStyle: TextStyle(color: T.text1, fontSize: 13),
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: T.surface2,
        hintStyle: const TextStyle(color: T.text3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rInput),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rInput),
          borderSide: const BorderSide(color: T.accent),
        ),
      ),
      textTheme: TextTheme(
        headlineMedium: T.mono(size: 30, weight: FontWeight.w700),
        titleLarge: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: T.text1),
        titleMedium: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: T.text1),
        bodyMedium: const TextStyle(fontSize: 14, color: T.text1),
        bodySmall: const TextStyle(fontSize: 12, color: T.text2),
      ),
    );
  }
}

extension UpDownColor on BuildContext {
  Color upColor() => T.up;
  Color downColor() => T.down;
  Color changeColor(double value) => T.changeColor(value);
}
