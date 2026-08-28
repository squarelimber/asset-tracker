import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';

class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.color,
    this.width = 72,
    this.height = 24,
  });

  final List<double> values;
  final Color? color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(width, height),
        painter: _SparklinePainter(values, color ?? T.accent),
      );
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var min = values.reduce(math.min);
    var max = values.reduce(math.max);
    final span = max - min == 0 ? 1.0 : max - min;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = size.height - (values[i] - min) / span * (size.height - 4) - 2;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.color != color;
}
