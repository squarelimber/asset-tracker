import 'package:flutter/material.dart';

import '../tokens.dart';

/// Calendar heatmap cell. [label] null/empty renders a pure color dot.
class HeatCell extends StatelessWidget {
  const HeatCell({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.label,
    this.child,
    this.labelSize = 10,
    this.onTap,
    this.width,
    this.height = 34,
  });

  final double value;
  final double min;
  final double max;
  final String? label;
  /// Custom content (e.g. day number + profit); overrides [label].
  final Widget? child;
  final double labelSize;
  final VoidCallback? onTap;
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cell = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: T.heat(value, min, max),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: T.borderSoft),
      ),
      alignment: Alignment.center,
      child: child ??
          (label == null || label!.isEmpty
              ? null
              : Text(label!, style: T.mono(size: labelSize, color: T.changeColor(value), weight: FontWeight.w600))),
    );
    if (onTap == null) return cell;
    return InkWell(borderRadius: BorderRadius.circular(4), onTap: onTap, child: cell);
  }
}
