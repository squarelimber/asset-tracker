import 'package:flutter/material.dart';

import '../tokens.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      Expanded(child: Text(label, style: T.label(size: 12, color: T.text2))),
    ];
    if (trailing != null) children.add(trailing!);
    return Padding(
      padding: const EdgeInsets.only(bottom: T.s2),
      child: Row(children: children),
    );
  }
}

/// Pinned section header for CustomScrollView pages.
class StickySectionHeader extends SliverPersistentHeaderDelegate {
  const StickySectionHeader({required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  double get maxExtent => 36;
  @override
  double get minExtent => 36;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) =>
      Container(color: T.bg, child: SectionHeader(label: label, trailing: trailing));

  @override
  bool shouldRebuild(covariant StickySectionHeader old) =>
      label != old.label || trailing != old.trailing;
}
