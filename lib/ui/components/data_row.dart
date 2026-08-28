import 'package:flutter/material.dart';

import '../tokens.dart';

/// One list row: title/subtitle left, mono amount block right.
class DataRow extends StatelessWidget {
  const DataRow({
    super.key,
    required this.title,
    required this.trailing,
    this.subtitle,
    this.leading,
    this.onTap,
    this.showChevron = false,
  });

  final String title;
  final Widget? subtitle;
  final Widget trailing;
  final Widget? leading;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final titleCol = <Widget>[
      Text(title, style: const TextStyle(fontSize: 14, color: T.text1)),
    ];
    if (subtitle != null) titleCol.add(subtitle!);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: T.s2),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: T.s2)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: titleCol,
            ),
          ),
          trailing,
          if (showChevron) const Icon(Icons.chevron_right, size: 18, color: T.text3),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}
