import 'package:flutter/material.dart';

/// Responsive layout helpers: phone single column, desktop multi-column.
class Responsive {
  Responsive._();

  static const double _tabletBreakpoint = 720;
  static const double _desktopBreakpoint = 1100;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= _desktopBreakpoint;

  static bool isTablet(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= _tabletBreakpoint;

  static bool isPhone(BuildContext context) => !isTablet(context);

  static double contentMaxWidth(BuildContext context) =>
      isDesktop(context) ? 1280 : double.infinity;
}

/// A scrollable, centered content shell used by desktop layouts.
class ResponsiveShell extends StatelessWidget {
  const ResponsiveShell({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final effectivePadding = padding ??
        EdgeInsets.symmetric(
          horizontal: Responsive.isPhone(context) ? 16 : 24,
          vertical: 16,
        );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Padding(padding: effectivePadding, child: child),
      ),
    );
  }
}

/// A simple responsive grid: 1 column on phone, 2 on tablet, 3 on desktop.
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({super.key, required this.children, this.spacing = 16});

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final columns = Responsive.isPhone(context) ? 1 : (Responsive.isTablet(context) ? 2 : 3);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        final tiles = <Widget>[];
        for (var i = 0; i < children.length; i++) {
          tiles.add(SizedBox(width: width, child: children[i]));
          if (i != children.length - 1) {
            tiles.add(SizedBox(width: spacing));
          }
        }
        return Wrap(spacing: 0, runSpacing: spacing, children: tiles);
      },
    );
  }
}
