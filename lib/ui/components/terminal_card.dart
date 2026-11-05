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
    return Padding(
      padding: margin,
      child: Material(
        color: T.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rCard),
          side: const BorderSide(color: T.border),
        ),
        child: onTap == null
            ? Padding(padding: padding, child: child)
            : InkWell(
                onTap: onTap,
                child: Padding(padding: padding, child: child),
              ),
      ),
    );
  }
}
