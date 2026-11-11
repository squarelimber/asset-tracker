import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../core/enums.dart';
import '../../data/database.dart';
import '../../services/market/kline_source.dart';
import '../tokens.dart';

enum KlineTradeMarkerType { buy, sell, t }

/// Transactions for one recorded calendar day, grouped for one chart marker.
class KlineTradeMarker {
  const KlineTradeMarker({
    required this.date,
    required this.type,
    required this.transactions,
  });

  final DateTime date;
  final KlineTradeMarkerType type;
  final List<TransactionRow> transactions;
}

/// Groups only trades in which the holding is the subject. Cash-counterparty
/// transactions are deliberately excluded. Dates follow the app's existing
/// local-date convention, including manually selected historical dates.
List<KlineTradeMarker> buildKlineTradeMarkers(
  List<TransactionRow> transactions,
  int holdingId,
) {
  final byDay = <DateTime, List<TransactionRow>>{};
  for (final transaction in transactions) {
    if (transaction.holdingId != holdingId) continue;
    final type = TransactionType.fromStorage(transaction.type);
    if (type != TransactionType.buy && type != TransactionType.sell) continue;
    final local = transaction.occurredAt.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    (byDay[day] ??= []).add(transaction);
  }
  final days = byDay.keys.toList()..sort();
  return [
    for (final day in days)
      KlineTradeMarker(
        date: day,
        type:
            byDay[day]!.any((t) => t.type == TransactionType.buy.storageName) &&
                byDay[day]!.any(
                  (t) => t.type == TransactionType.sell.storageName,
                )
            ? KlineTradeMarkerType.t
            : byDay[day]!.first.type == TransactionType.buy.storageName
            ? KlineTradeMarkerType.buy
            : KlineTradeMarkerType.sell,
        transactions: byDay[day]!
          ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt)),
      ),
  ];
}

/// Associates markers with a candle in the same calendar day, week or month.
/// Missing periods are never substituted with a neighbouring candle.
Map<int, List<KlineTradeMarker>> mapKlineMarkersToBars(
  List<CandleBar> bars,
  List<KlineTradeMarker> markers,
  KlinePeriod period,
) {
  DateTime periodKey(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    return switch (period) {
      KlinePeriod.day => day,
      KlinePeriod.week => day.subtract(Duration(days: day.weekday - 1)),
      KlinePeriod.month => DateTime(day.year, day.month),
    };
  }

  final indexes = <DateTime, int>{
    for (var index = 0; index < bars.length; index++)
      periodKey(bars[index].date): index,
  };
  final result = <int, List<KlineTradeMarker>>{};
  for (final marker in markers) {
    final index = indexes[periodKey(marker.date)];
    if (index != null) (result[index] ??= []).add(marker);
  }
  return result;
}

class _TradePricePoint {
  const _TradePricePoint(this.index, this.price, this.marker, this.transaction);

  final int index;
  final double price;
  final KlineTradeMarker marker;
  final TransactionRow transaction;
}

class _PlacedPricePoint {
  const _PlacedPricePoint(this.trade, this.position);

  final _TradePricePoint trade;
  final Offset position;
}

class _TradePriceCluster {
  _TradePriceCluster(this.points, this.bounds);

  final List<_PlacedPricePoint> points;
  Rect bounds;
}

/// Interactive OHLC and volume chart. The newest candles appear on the right.
class KlineChart extends StatefulWidget {
  const KlineChart({
    super.key,
    required this.bars,
    this.markers = const [],
    this.period = KlinePeriod.day,
    this.onMarkerTap,
    this.hideTradePrices = false,
  });

  final List<CandleBar> bars;
  final List<KlineTradeMarker> markers;
  final KlinePeriod period;
  final ValueChanged<List<KlineTradeMarker>>? onMarkerTap;

  /// Keeps transaction prices private while retaining date-only markers.
  final bool hideTradePrices;

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
    final markersByBar = mapKlineMarkersToBars(
      widget.bars,
      widget.markers,
      widget.period,
    );
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
            final chartWidth = math.max(1.0, width - 54);
            final slots = math.max(1, (chartWidth / 64).floor());
            final slotWidth = chartWidth / slots;
            final dateClusters = <int, List<KlineTradeMarker>>{};
            final dateMarkerIndexes = <int>[];
            final pricedTrades = <_TradePricePoint>[];
            final visible = widget.bars.sublist(_start, _end);
            var low = visible.map((bar) => bar.low).reduce(math.min);
            var high = visible.map((bar) => bar.high).reduce(math.max);
            final tolerance = math.max((high - low) * 0.25, high * 0.03);
            final allowedLow = low - tolerance;
            final allowedHigh = high + tolerance;
            var hasUnplottedPrices = false;
            for (final entry in markersByBar.entries) {
              if (entry.key < _start || entry.key >= _end) continue;
              for (final marker in entry.value) {
                var needsDateMarker = widget.hideTradePrices;
                if (!widget.hideTradePrices) {
                  for (final transaction in marker.transactions) {
                    final price = transaction.price;
                    if (price == null ||
                        !price.isFinite ||
                        price <= 0 ||
                        price < allowedLow ||
                        price > allowedHigh) {
                      needsDateMarker = true;
                      hasUnplottedPrices = true;
                      continue;
                    }
                    pricedTrades.add(
                      _TradePricePoint(entry.key, price, marker, transaction),
                    );
                    low = math.min(low, price);
                    high = math.max(high, price);
                  }
                }
                if (needsDateMarker) {
                  final x =
                      (entry.key - _start + 0.5) / (_end - _start) * chartWidth;
                  final slot = (x / slotWidth).floor().clamp(0, slots - 1);
                  (dateClusters[slot] ??= []).add(marker);
                  dateMarkerIndexes.add(entry.key);
                }
              }
            }
            final top = dateMarkerIndexes.isNotEmpty ? 48.0 : 8.0;
            const chartBottom = 320 * 0.72;
            final padding = math.max((high - low) * 0.06, high * 0.001);
            final maximum = high + padding;
            final minimum = low - padding;
            final placed = <_PlacedPricePoint>[];
            for (final trade in pricedTrades) {
              final x =
                  (trade.index - _start + 0.5) / (_end - _start) * chartWidth;
              final y =
                  top +
                  (maximum - trade.price) /
                      (maximum - minimum) *
                      (chartBottom - top);
              placed.add(_PlacedPricePoint(trade, Offset(x, y)));
            }
            final priceClusters = _clusterPriceMarkers(
              placed,
              chartWidth,
              top,
              chartBottom,
            );
            final priceHitAreas = priceClusters
                .map((cluster) => cluster.bounds)
                .toList();
            bool isMarkerArea(Offset position) =>
                (dateMarkerIndexes.isNotEmpty && position.dy < 48) ||
                priceHitAreas.any((rect) => rect.contains(position));
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      _zoom(event.scrollDelta.dy < 0 ? 0.8 : 1.25);
                    }
                  },
                  child: MouseRegion(
                    onHover: (event) {
                      if (!isMarkerArea(event.localPosition)) {
                        _select(event.localPosition, width);
                      }
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) {
                        if (!isMarkerArea(details.localPosition)) {
                          _select(details.localPosition, width);
                        }
                      },
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
                        child: Stack(
                          clipBehavior: Clip.hardEdge,
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _KlinePainter(
                                  widget.bars,
                                  _start,
                                  _end,
                                  _selected,
                                  dateMarkerIndexes,
                                  placed,
                                  priceClusters,
                                  minimum,
                                  maximum,
                                ),
                              ),
                            ),
                            if (widget.onMarkerTap != null)
                              for (final entry in dateClusters.entries)
                                _markerButton(
                                  entry.key,
                                  entry.value,
                                  slotWidth,
                                ),
                            if (widget.onMarkerTap != null)
                              for (final cluster in priceClusters)
                                _priceMarkerButton(cluster),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (hasUnplottedPrices)
                  Text('部分交易缺少有效价格或超出图表范围，按日期显示在图上方。', style: T.label()),
              ],
            );
          },
        ),
        const SizedBox(height: T.s1),
        Text('拖动查看历史 · 双指或滚轮缩放 · 点击查看数据', style: T.label(color: T.text3)),
      ],
    );
  }

  List<_TradePriceCluster> _clusterPriceMarkers(
    List<_PlacedPricePoint> points,
    double chartWidth,
    double top,
    double bottom,
  ) {
    final clusters = <_TradePriceCluster>[];
    final buttonWidth = math.min(84.0, chartWidth);
    Rect boundsFor(List<_PlacedPricePoint> points) {
      final centerX =
          points.map((point) => point.position.dx).reduce((a, b) => a + b) /
          points.length;
      final centerY =
          points.map((point) => point.position.dy).reduce((a, b) => a + b) /
          points.length;
      final left = (centerX - buttonWidth / 2).clamp(
        0.0,
        chartWidth - buttonWidth,
      );
      final y = (centerY - 44).clamp(top, bottom - 44);
      return Rect.fromLTWH(left, y, buttonWidth, 44);
    }

    for (final point in points) {
      final members = <_PlacedPricePoint>[point];
      var bounds = boundsFor(members);
      var index = 0;
      while (index < clusters.length) {
        if (bounds.overlaps(clusters[index].bounds)) {
          members.addAll(clusters.removeAt(index).points);
          bounds = boundsFor(members);
          index = 0;
        } else {
          index++;
        }
      }
      members.sort(
        (a, b) => a.trade.transaction.occurredAt.compareTo(
          b.trade.transaction.occurredAt,
        ),
      );
      clusters.add(_TradePriceCluster(members, bounds));
    }
    return clusters;
  }

  Widget _priceMarkerButton(_TradePriceCluster cluster) {
    final labels = <String>{
      for (final point in cluster.points)
        point.trade.transaction.type == TransactionType.buy.storageName
            ? 'B'
            : 'S',
    };
    final hasT = cluster.points.any(
      (point) => point.trade.marker.type == KlineTradeMarkerType.t,
    );
    final count = cluster.points.length > 1 ? '·${cluster.points.length}' : '';
    final prices = cluster.points.map((point) => point.trade.price).toSet();
    final price = prices.length == 1
        ? ' ${Formats.plainNum(prices.single, decimals: 4)}'
        : '';
    final days = cluster.points
        .map((point) => Formats.date(point.trade.marker.date))
        .toSet();
    final date = days.length == 1
        ? days.single.substring(5)
        : '${days.length}个交易日';
    final label = '${labels.join('/')}${hasT ? '·T' : ''}$count$price\n$date';
    final markers = <KlineTradeMarker>{
      for (final point in cluster.points) point.trade.marker,
    }.toList();
    return Positioned.fromRect(
      rect: cluster.bounds,
      child: Tooltip(
        message: '${cluster.points.length} 笔交易',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey(
              'price-marker-${cluster.points.map((point) => point.trade.transaction.id).join('-')}',
            ),
            onTap: () => widget.onMarkerTap!(markers),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                decoration: BoxDecoration(
                  color: T.surface2,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: T.accent),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: T.mono(
                      size: 11,
                      color: T.accent,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _markerButton(
    int slot,
    List<KlineTradeMarker> markers,
    double slotWidth,
  ) {
    final labels = <String>{
      for (final marker in markers)
        switch (marker.type) {
          KlineTradeMarkerType.buy => 'B',
          KlineTradeMarkerType.sell => 'S',
          KlineTradeMarkerType.t => 'T',
        },
    };
    final count = markers.fold<int>(
      0,
      (sum, marker) => sum + marker.transactions.length,
    );
    final label = '${labels.join('/')}·$count';
    return Positioned(
      left: slot * slotWidth + (slotWidth - 64) / 2,
      top: 0,
      width: 64,
      height: 44,
      child: Tooltip(
        message: '${markers.length} 个交易日 · $count 笔交易',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => widget.onMarkerTap!(markers),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                decoration: BoxDecoration(
                  color: T.surface2,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: T.accent),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: T.mono(
                      size: 11,
                      color: T.accent,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _maColors = [Color(0xFFD5B276), Color(0xFF91AEC7), Color(0xFFB89CC6)];

class _KlinePainter extends CustomPainter {
  const _KlinePainter(
    this.bars,
    this.start,
    this.end,
    this.selected,
    this.markerIndexes,
    this.pricedTrades,
    this.priceClusters,
    this.minimum,
    this.maximum,
  );

  final List<CandleBar> bars;
  final int start;
  final int end;
  final int? selected;
  final List<int> markerIndexes;
  final List<_PlacedPricePoint> pricedTrades;
  final List<_TradePriceCluster> priceClusters;
  final double minimum;
  final double maximum;

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
    final top = markerIndexes.isNotEmpty ? 48.0 : 8.0;
    final chartBottom = size.height * 0.72;
    final volumeTop = chartBottom + 14;
    final volumeBottom = size.height - 20;
    final visible = bars.sublist(start, end);
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
    final markerLine = Paint()
      ..color = T.accent
      ..strokeWidth = 1;
    for (final index in markerIndexes) {
      final x = (index - start + 0.5) * step;
      canvas.drawLine(Offset(x, top - 6), Offset(x, top), markerLine);
    }
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
    final connector = Paint()
      ..color = T.accent.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    for (final cluster in priceClusters) {
      for (final point in cluster.points) {
        canvas.drawLine(cluster.bounds.bottomCenter, point.position, connector);
      }
    }
    for (final point in pricedTrades) {
      canvas.drawCircle(point.position, 3, Paint()..color = T.accent);
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
      old.selected != selected ||
      !listEquals(old.markerIndexes, markerIndexes) ||
      old.pricedTrades != pricedTrades ||
      old.priceClusters != priceClusters ||
      old.minimum != minimum ||
      old.maximum != maximum;
}
