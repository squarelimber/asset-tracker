import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/market/kline_source.dart';
import 'package:asset_tracker/ui/components/kline_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TransactionRow trade(
  int id,
  String type,
  DateTime date, {
  int? holdingId = 1,
  double? price,
}) => TransactionRow(
  id: id,
  accountId: 1,
  holdingId: holdingId,
  type: type,
  amount: 100,
  price: price,
  currency: 'CNY',
  occurredAt: date,
  updatedAt: date,
  costMoved: true,
  internalMove: false,
);

CandleBar bar(int year, int month, int day) => CandleBar(
  date: DateTime(year, month, day),
  open: 10,
  high: 12,
  low: 9,
  close: 11,
  volume: 100,
);

void main() {
  testWidgets('同日 T 的买入卖出按各自真实价格定位', (tester) async {
    final rows = [
      trade(1, 'buy', DateTime(2026, 11, 2, 9), price: 10),
      trade(2, 'sell', DateTime(2026, 11, 2, 14), price: 11),
    ];
    List<KlineTradeMarker>? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KlineChart(
            bars: [bar(2026, 11, 2)],
            markers: buildKlineTradeMarkers(rows, 1),
            onMarkerTap: (value) => selected = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final buy = find.byKey(const ValueKey('price-marker-1'));
    final sell = find.byKey(const ValueKey('price-marker-2'));
    expect(find.text('B·T 10\n11-02'), findsOneWidget);
    expect(find.text('S·T 11\n11-02'), findsOneWidget);
    expect(tester.getCenter(sell).dy, lessThan(tester.getCenter(buy).dy));
    expect(tester.getSize(buy).height, greaterThanOrEqualTo(44));
    await tester.tap(buy);
    expect(selected!.single.transactions.length, 2);
  });

  testWidgets('隐藏交易价格时只按日期展示标记', (tester) async {
    final rows = [
      trade(1, 'buy', DateTime(2026, 11, 2, 9), price: 10),
      trade(2, 'sell', DateTime(2026, 11, 2, 14), price: 11),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KlineChart(
            bars: [bar(2026, 11, 2)],
            markers: buildKlineTradeMarkers(rows, 1),
            hideTradePrices: true,
            onMarkerTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('T·2'), findsOneWidget);
    expect(find.text('B·T 10\n11-02'), findsNothing);
    expect(find.byKey(const ValueKey('price-marker-1')), findsNothing);
  });

  testWidgets('相近价格标记合并并保留不同日期的记录', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bars = [for (var day = 1; day <= 20; day++) bar(2026, 11, day)];
    final rows = [
      trade(1, 'buy', DateTime(2026, 11, 2), price: 10),
      trade(2, 'sell', DateTime(2026, 11, 3), price: 10),
    ];
    List<KlineTradeMarker>? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KlineChart(
            bars: bars,
            markers: buildKlineTradeMarkers(rows, 1),
            onMarkerTap: (value) => selected = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final combined = find.text('B/S·2 10\n2个交易日');
    expect(combined, findsOneWidget);
    await tester.tap(combined);
    expect(selected!.map((marker) => marker.date.day).toSet(), {2, 3});
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺价格或明显超出范围时保留日期标记并说明', (tester) async {
    final rows = [
      trade(1, 'buy', DateTime(2026, 11, 2, 9)),
      trade(2, 'sell', DateTime(2026, 11, 2, 14), price: 500),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KlineChart(
            bars: [bar(2026, 11, 2)],
            markers: buildKlineTradeMarkers(rows, 1),
            onMarkerTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('T·2'), findsOneWidget);
    expect(find.textContaining('缺少有效价格或超出图表范围'), findsOneWidget);
    expect(find.byKey(const ValueKey('price-marker-2')), findsNothing);
  });

  test('T requires both buys and sells on the same recorded day', () {
    final rows = [
      trade(1, 'sell', DateTime(2026, 11, 2, 9)),
      trade(2, 'buy', DateTime(2026, 11, 2, 14)),
      trade(3, 'buy', DateTime(2026, 11, 3, 9)),
      trade(4, 'sell', DateTime(2026, 11, 4, 9)),
      trade(5, 'buy', DateTime(2026, 11, 2, 12), holdingId: 2),
      trade(6, 'transfer_out', DateTime(2026, 11, 2, 12)),
    ];
    final markers = buildKlineTradeMarkers(rows, 1);
    expect(markers.map((m) => m.type), [
      KlineTradeMarkerType.t,
      KlineTradeMarkerType.buy,
      KlineTradeMarkerType.sell,
    ]);
    expect(markers.first.transactions.map((row) => row.id), [1, 2]);
  });

  test('day, week and month map only to matching calendar periods', () {
    final rows = [
      trade(1, 'buy', DateTime(2026, 11, 2)),
      trade(2, 'sell', DateTime(2026, 11, 4)),
      trade(3, 'buy', DateTime(2026, 12, 1)),
    ];
    final markers = buildKlineTradeMarkers(rows, 1);
    final daily = mapKlineMarkersToBars(
      [bar(2026, 11, 4)],
      markers,
      KlinePeriod.day,
    );
    expect(daily[0]!.single.transactions.single.id, 2);
    final weekly = mapKlineMarkersToBars(
      [bar(2026, 11, 6)],
      markers,
      KlinePeriod.week,
    );
    expect(weekly[0]!.map((m) => m.type), [
      KlineTradeMarkerType.buy,
      KlineTradeMarkerType.sell,
    ]);
    final monthly = mapKlineMarkersToBars(
      [bar(2026, 11, 30)],
      markers,
      KlinePeriod.month,
    );
    expect(monthly[0]!.length, 2);
  });

  testWidgets('trade marker opens all transactions for its candle', (
    tester,
  ) async {
    List<KlineTradeMarker>? selected;
    final rows = [
      trade(1, 'buy', DateTime(2026, 11, 2)),
      trade(2, 'sell', DateTime(2026, 11, 2, 12)),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KlineChart(
            bars: [bar(2026, 11, 2)],
            markers: buildKlineTradeMarkers(rows, 1),
            onMarkerTap: (markers) => selected = markers,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('T·2'));
    expect(selected!.single.transactions.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nearby markers are grouped into one touch target', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    List<KlineTradeMarker>? selected;
    final bars = [for (var day = 1; day <= 20; day++) bar(2026, 11, day)];
    final rows = [
      trade(1, 'buy', DateTime(2026, 11, 2)),
      trade(2, 'sell', DateTime(2026, 11, 3)),
      trade(3, 'buy', DateTime(2026, 11, 4)),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KlineChart(
            bars: bars,
            markers: buildKlineTradeMarkers(rows, 1),
            onMarkerTap: (markers) => selected = markers,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('B/S·3'));
    expect(selected!.map((marker) => marker.date.day), [2, 3, 4]);
    final button = find.ancestor(
      of: find.text('B/S·3'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(button).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
  });

  testWidgets('separated trade markers remain independently tappable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final start = DateTime(2026, 1, 1);
    final bars = [
      for (var index = 0; index < 60; index++)
        bar(start.year, start.month, start.day + index),
    ];
    final markers = buildKlineTradeMarkers([
      trade(1, 'buy', start.add(const Duration(days: 2))),
      trade(2, 'sell', start.add(const Duration(days: 57))),
    ], 1);
    List<KlineTradeMarker>? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KlineChart(
            bars: bars,
            markers: markers,
            onMarkerTap: (value) => selected = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final buy = find.ancestor(
      of: find.text('B·1'),
      matching: find.byType(InkWell),
    );
    final sell = find.ancestor(
      of: find.text('S·1'),
      matching: find.byType(InkWell),
    );
    expect(tester.getRect(buy).overlaps(tester.getRect(sell)), isFalse);
    await tester.tap(buy);
    expect(selected!.single.transactions.single.id, 1);
    await tester.tap(sell);
    expect(selected!.single.transactions.single.id, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hovering and tapping a marker does not change the selected candle',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bars = [
        for (var index = 0; index < 10; index++)
          CandleBar(
            date: DateTime(2026, 11, index + 1),
            open: 10 + index.toDouble(),
            high: 12 + index.toDouble(),
            low: 9 + index.toDouble(),
            close: 11 + index.toDouble(),
            volume: 100,
          ),
      ];
      final markers = buildKlineTradeMarkers([
        trade(1, 'sell', DateTime(2026, 11, 1, 9)),
        trade(2, 'buy', DateTime(2026, 11, 1, 14)),
      ], 1);
      List<KlineTradeMarker>? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KlineChart(
              bars: bars,
              markers: markers,
              onMarkerTap: (value) => selected = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('收 20.00'), findsOneWidget);
      final marker = find.text('T·2');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(319, 0));
      await mouse.moveTo(tester.getCenter(marker));
      await tester.pump();
      expect(find.text('收 20.00'), findsOneWidget);
      await tester.tap(marker);
      await tester.pump();
      expect(selected!.single.transactions.length, 2);
      expect(find.text('收 20.00'), findsOneWidget);
      await mouse.removePointer();
      final paint = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter.runtimeType.toString() == '_KlinePainter',
      );
      await tester.tapAt(tester.getTopLeft(paint) + const Offset(8, 100));
      await tester.pump();
      expect(find.text('收 11.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
