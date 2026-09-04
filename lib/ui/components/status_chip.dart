import 'package:flutter/material.dart';

import '../tokens.dart';

/// Small status chip (清仓 / 已还清 / 已结清 / 已归档) shown next to a
/// holding's name in lists, tables and the detail sheet.
class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: T.surface2,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: T.border),
      ),
      child: Text(label, style: T.mono(size: 10, color: T.text2)),
    );
  }
}
