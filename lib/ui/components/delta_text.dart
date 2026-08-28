import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../tokens.dart';

class DeltaText extends StatelessWidget {
  const DeltaText({super.key, required this.value, this.text, this.size = 13});

  final double value;
  final String? text;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      text ?? Formats.pct1(value),
      style: T.mono(size: size, color: T.changeColor(value), weight: FontWeight.w600),
    );
  }
}
