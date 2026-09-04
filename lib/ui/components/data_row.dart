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
    this.titleSuffix,
    this.dimmed = false,
  });

  final String title;
  final Widget? subtitle;
  final Widget trailing;
  final Widget? leading;
  final VoidCallback? onTap;
  final bool showChevron;

  /// Small chip rendered right after the title (e.g. 清仓 / 已还清).
  final Widget? titleSuffix;

  /// Dim the title for inactive rows (sold-out / archived holdings).
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final titleStyle = TextStyle(fontSize: 14, color: dimmed ? T.text3 : T.text1);
    final titleCol = <Widget>[
      if (titleSuffix == null)
        Text(title, style: titleStyle)
      else
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
            titleSuffix!,
          ],
        ),
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
