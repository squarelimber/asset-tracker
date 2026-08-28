import 'package:flutter/material.dart';

import '../tokens.dart';

class TerminalCard extends StatelessWidget {
  const TerminalCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(T.s3),
    this.margin = const EdgeInsets.only(bottom: T.s3),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: T.border),
      ),
      child: child,
    );
    if (onTap == null) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(T.rCard),
      onTap: onTap,
      child: card,
    );
  }
}
