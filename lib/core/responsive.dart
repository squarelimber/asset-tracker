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

/// A top-aligned, horizontally centered content shell used by desktop layouts.
/// (Top alignment avoids the big gap above content when the page is short.)
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
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Padding(padding: effectivePadding, child: child),
      ),
    );
  }
}

/// A responsive grid of equal-width cards.
///
/// Unlike a `Wrap` of fixed-size tiles, cards are grouped into rows so every
/// card in a row is exactly the same width and the row always spans the full
/// available width (no leftover gap on the right). Cards keep their natural
/// height and are top-aligned within the row.
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({
    super.key,
    required this.children,
    this.spacing = 16,
    this.maxColumns,
  });

  final List<Widget> children;
  final double spacing;

  /// Override the column count (e.g. 2 on desktop). Defaults to
  /// 1 phone / 2 tablet / 3 desktop.
  final int? maxColumns;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final columns = maxColumns ??
        (Responsive.isPhone(context) ? 1 : (Responsive.isTablet(context) ? 2 : 3));

    final rows = <List<Widget>>[];
    for (var i = 0; i < children.length; i += columns) {
      rows.add(children.sublist(
        i,
        i + columns > children.length ? children.length : i + columns,
      ));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Standard card width for a full row; used for the last (partial)
        // row so a single leftover card is not stretched across the page.
        final cardWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) SizedBox(height: spacing),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var c = 0; c < rows[r].length; c++) ...[
                    if (c > 0) SizedBox(width: spacing),
                    if (r == rows.length - 1 && rows[r].length < columns)
                      SizedBox(width: cardWidth, child: rows[r][c])
                    else
                      Expanded(child: rows[r][c]),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
