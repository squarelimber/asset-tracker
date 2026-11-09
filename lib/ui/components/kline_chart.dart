import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../services/market/kline_source.dart';
import '../tokens.dart';

/// Interactive OHLC and volume chart. The newest candles appear on the right.
class KlineChart extends StatefulWidget {
  const KlineChart({super.key, required this.bars});

  final List<CandleBar> bars;

  @override
  State<KlineChart> createState() => _KlineChartState();
}

class _KlineChartState extends State<KlineChart> {
  int _visible = 60;
  int _end = 0;
  int? _selected;
  int _gestureEnd = 0;
  int _gestureVisible = 60;
  Offset _gestureStart = Offset.zero;

  @override
  void initState() {
    super.initState();
    _end = widget.bars.length;
  }

  @override
  void didUpdateWidget(covariant KlineChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bars != widget.bars) {
      _end = widget.bars.length;
      _selected = null;
    }
  }

  int get _count => math.min(_visible, widget.bars.length);
  int get _start => math.max(0, _end - _count);

  void _select(Offset local, double width) {
    if (widget.bars.isEmpty || width <= 54) return;
    final x = local.dx.clamp(0.0, width - 54);
    final index = (_start + (x / (width - 54) * (_end - _start)).floor()).clamp(
      _start,
      _end - 1,
    );
    if (_selected != index) setState(() => _selected = index);
  }

  void _zoom(double factor) {
    if (widget.bars.isEmpty) return;
    setState(() {
      _visible = (_visible * factor).round().clamp(20, 180);
      _end = _end.clamp(
        math.min(_visible, widget.bars.length),
        widget.bars.length,
      );
      _selected = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bars.isEmpty) return const SizedBox.shrink();
    final bar = widget.bars[_selected ?? (_end - 1)];
    final direction = bar.close - bar.open;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            Text(Formats.date(bar.date), style: T.mono(size: 12)),
            Text('开 ${Formats.amount(bar.open)}', style: T.mono(size: 12)),
            Text('高 ${Formats.amount(bar.high)}', style: T.mono(size: 12)),
            Text('低 ${Formats.amount(bar.low)}', style: T.mono(size: 12)),
            Text(
              '收 ${Formats.amount(bar.close)}',
              style: T.mono(size: 12, color: T.changeColor(direction)),
            ),
            Text(
              '成交量 ${Formats.amountCompact(bar.volume)}',
              style: T.mono(size: 12, color: T.text2),
            ),
          ],
        ),
        const SizedBox(height: T.s2),
        Wrap(
          spacing: 12,
          children: [
            for (final (index, period) in [5, 10, 20].indexed)
              Text(
                'MA$period',
                style: T.mono(size: 11, color: _maColors[index]),
              ),
          ],
        ),
        const SizedBox(height: T.s1),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  _zoom(event.scrollDelta.dy < 0 ? 0.8 : 1.25);
                }
              },
              child: MouseRegion(
                onHover: (event) => _select(event.localPosition, width),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => _select(details.localPosition, width),
                  onScaleStart: (details) {
                    _gestureStart = details.localFocalPoint;
                    _gestureEnd = _end;
                    _gestureVisible = _visible;
                  },
                  onScaleUpdate: (details) {
                    setState(() {
                      _visible = (_gestureVisible / details.scale)
                          .round()
                          .clamp(20, 180);
                      final count = math.min(_visible, widget.bars.length);
                      final chartWidth = math.max(1.0, width - 54);
                      final offset =
                          ((details.localFocalPoint.dx - _gestureStart.dx) /
                                  chartWidth *
                                  count)
                              .round();
                      _end = (_gestureEnd - offset).clamp(
                        count,
                        widget.bars.length,
                      );
                      _selected = null;
                    });
                  },
                  child: SizedBox(
                    height: 320,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _KlinePainter(
                        widget.bars,
                        _start,
                        _end,
                        _selected,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: T.s1),
        Text('拖动查看历史 · 双指或滚轮缩放 · 点击查看数据', style: T.label(color: T.text3)),
      ],
    );
  }
}

const _maColors = [Color(0xFFD5B276), Color(0xFF91AEC7), Color(0xFFB89CC6)];

class _KlinePainter extends CustomPainter {
  const _KlinePainter(this.bars, this.start, this.end, this.selected);

  final List<CandleBar> bars;
  final int start;
  final int end;
  final int? selected;

  void _text(
    Canvas canvas,
    String text,
    Offset position, {
    Color color = T.text3,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: T.mono(size: 10, color: color),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    painter.paint(canvas, position);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final width = math.max(1.0, size.width - 54);
    const top = 8.0;
    final chartBottom = size.height * 0.72;
    final volumeTop = chartBottom + 14;
    final volumeBottom = size.height - 20;
    final visible = bars.sublist(start, end);
    final high = visible.map((b) => b.high).reduce(math.max);
    final low = visible.map((b) => b.low).reduce(math.min);
    final padding = math.max((high - low) * 0.06, high * 0.001);
    final maximum = high + padding;
    final minimum = low - padding;
    final volumeMax = visible.map((b) => b.volume).reduce(math.max);
    double y(double value) =>
        top + (maximum - value) / (maximum - minimum) * (chartBottom - top);
    final grid = Paint()
      ..color = T.borderSoft
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final gridY = top + (chartBottom - top) * i / 4;
      canvas.drawLine(Offset(0, gridY), Offset(width, gridY), grid);
      _text(
        canvas,
        (maximum - (maximum - minimum) * i / 4).toStringAsFixed(2),
        Offset(width + 4, gridY - 6),
      );
    }
    canvas.drawLine(Offset(0, volumeTop), Offset(width, volumeTop), grid);
    final step = width / visible.length;
    final candleWidth = (step * 0.65).clamp(1.0, 12.0);
    for (var i = 0; i < visible.length; i++) {
      final b = visible[i];
      final x = (i + 0.5) * step;
      final color = b.close >= b.open ? T.up : T.down;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1;
      canvas.drawLine(Offset(x, y(b.high)), Offset(x, y(b.low)), paint);
      final bodyTop = y(math.max(b.open, b.close));
      final bodyBottom = y(math.min(b.open, b.close));
      canvas.drawRect(
        Rect.fromLTWH(
          x - candleWidth / 2,
          bodyTop,
          candleWidth,
          math.max(1, bodyBottom - bodyTop),
        ),
        paint,
      );
      if (volumeMax > 0) {
        final height = b.volume / volumeMax * (volumeBottom - volumeTop);
        canvas.drawRect(
          Rect.fromLTWH(
            x - candleWidth / 2,
            volumeBottom - height,
            candleWidth,
            height,
          ),
          paint..color = color.withValues(alpha: 0.65),
        );
      }
    }
    for (final (colorIndex, period) in [5, 10, 20].indexed) {
      final path = Path();
      var started = false;
      for (var index = start; index < end; index++) {
        if (index + 1 < period) continue;
        var sum = 0.0;
        for (var day = index - period + 1; day <= index; day++) {
          sum += bars[day].close;
        }
        final point = Offset((index - start + 0.5) * step, y(sum / period));
        if (started) {
          path.lineTo(point.dx, point.dy);
        } else {
          path.moveTo(point.dx, point.dy);
          started = true;
        }
      }
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, top, width, chartBottom - top));
      canvas.drawPath(
        path,
        Paint()
          ..color = _maColors[colorIndex]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      canvas.restore();
    }
    _text(
      canvas,
      Formats.date(visible.first.date),
      Offset(0, size.height - 14),
    );
    final lastLabel = Formats.date(visible.last.date);
    _text(canvas, lastLabel, Offset(math.max(0, width - 72), size.height - 14));
    if (selected != null && selected! >= start && selected! < end) {
      final x = (selected! - start + 0.5) * step;
      final selectedY = y(bars[selected!].close);
      final crosshair = Paint()
        ..color = T.text3.withValues(alpha: 0.7)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(x, top), Offset(x, volumeBottom), crosshair);
      canvas.drawLine(
        Offset(0, selectedY),
        Offset(width, selectedY),
        crosshair,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _KlinePainter old) =>
      old.bars != bars ||
      old.start != start ||
      old.end != end ||
      old.selected != selected;
}
