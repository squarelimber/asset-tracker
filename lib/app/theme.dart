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
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const ['Microsoft YaHei', 'Noto Sans SC', 'Arial'],
      scaffoldBackgroundColor: T.bg,
      hoverColor: T.text1.withValues(alpha: 0.04),
      focusColor: T.accent.withValues(alpha: 0.12),
      splashFactory: NoSplash.splashFactory,
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: T.text2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rInput),
          ),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: T.accent,
        selectionColor: T.accent.withValues(alpha: 0.24),
        selectionHandleColor: T.accent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: T.surface,
        selectedColor: T.surface2,
        side: const BorderSide(color: T.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rInput),
        ),
        labelStyle: const TextStyle(fontSize: 12, color: T.text2),
        secondaryLabelStyle: const TextStyle(fontSize: 12, color: T.text1),
        checkmarkColor: T.accent,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: T.surface2,
          border: Border.all(color: T.border),
          borderRadius: BorderRadius.circular(T.rInput),
        ),
        textStyle: const TextStyle(fontSize: 12, color: T.text1),
        waitDuration: const Duration(milliseconds: 450),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rInput),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 44),
          foregroundColor: T.text1,
          side: const BorderSide(color: T.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rInput),
          ),
        ),
      ),
      appBarTheme: const AppBarTheme(
        toolbarHeight: 56,
        titleSpacing: 20,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: T.text1,
        ),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: T.surface,
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
        selectedIconTheme: const IconThemeData(color: T.text1),
        unselectedIconTheme: const IconThemeData(color: T.text2),
        selectedLabelTextStyle: T.label(size: 11, color: T.text1),
        unselectedLabelTextStyle: T.label(size: 11, color: T.text2),
      ),
      dividerTheme: const DividerThemeData(color: T.border, thickness: 1),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: T.surface2,
        contentTextStyle: TextStyle(color: T.text1, fontSize: 13),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: T.surface2,
        surfaceTintColor: T.surface2,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(T.rCard)),
          side: BorderSide(color: T.border),
        ),
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: T.text1,
        ),
        contentTextStyle: TextStyle(fontSize: 14, color: T.text1),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: T.surface2,
        surfaceTintColor: T.surface2,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          side: BorderSide(color: T.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: T.surface2,
        hintStyle: const TextStyle(color: T.text3),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rInput),
          borderSide: const BorderSide(color: T.border),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rInput),
          borderSide: const BorderSide(color: T.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rInput),
          borderSide: const BorderSide(color: T.accent),
        ),
      ),
      textTheme: TextTheme(
        headlineMedium: T.mono(size: 30, weight: FontWeight.w700),
        titleLarge: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: T.text1,
        ),
        titleMedium: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: T.text1,
        ),
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
