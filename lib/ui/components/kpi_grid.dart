import 'package:flutter/material.dart';

import '../../core/responsive.dart';
import '../tokens.dart';
import 'delta_text.dart';
import 'terminal_card.dart';

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.delta,
    this.color,
  });

  final String label;
  final String value;
  final double? delta;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return TerminalCard(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: T.label()),
          const SizedBox(height: T.s1),
          Text(value, style: T.mono(size: 20, weight: FontWeight.w600, color: color ?? T.text1)),
          if (delta != null) ...[
            const SizedBox(height: T.s1),
            DeltaText(value: delta!),
          ],
        ],
      ),
    );
  }
}

class KpiGrid extends StatelessWidget {
  const KpiGrid({super.key, required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    final columns = Responsive.isDesktop(context) ? 4 : 2;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth =
            (constraints.maxWidth - T.s3 * (columns - 1)) / columns;
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: T.s3,
          crossAxisSpacing: T.s3,
          childAspectRatio: cellWidth / 140,
          children: tiles,
        );
      },
    );
  }
}
