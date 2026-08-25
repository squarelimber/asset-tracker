import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:asset_tracker/features/calendar/product_earnings_calendar_page.dart';

/// A product with one baseline day and one profit day per month of [year],
/// so every month has data (days = 2) and a deterministic rate. The value
/// carries over between months (it never resets), so each month's profit is
/// exactly [monthlyProfits][m-1] and the yearly rates stay distinct.
ProductEarnings _product(String name, List<double> monthlyProfits, int year) {
  final daily = <({String date, double value, double cost})>[];
  var value = 10000.0;
  for (var m = 1; m <= 12; m++) {
    final mm = m.toString().padLeft(2, '0');
    daily.add((date: '$year-$mm-01', value: value, cost: 10000));
    value += monthlyProfits[m - 1];
    daily.add((date: '$year-$mm-15', value: value, cost: 10000));
  }
  return ProductEarnings(
    name: name,
    type: AssetType.mutualFund,
    closed: false,
    daily: daily,
  );
}

Future<void> _pump(
  WidgetTester tester,
  List<ProductEarnings> products, {
  int year = 2025,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final nowYear = DateTime.now().year;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      // The page starts on the current year; keep it empty so the real
      // provider (and its DB access) is never evaluated. Sync overrides skip
      // the loading state (no infinite spinner for pumpAndSettle).
      if (nowYear != year)
        productEarningsProvider(nowYear).overrideWith((ref) => const []),
      productEarningsProvider(year).overrideWith((ref) => products),
    ],
    child: const MaterialApp(home: ProductEarningsCalendarPage()),
  ));
  await tester.pump();
}

void main() {
  testWidgets('name column stays pinned while the grid scrolls horizontally',
      (tester) async {
    await _pump(tester, [
      _product('产品甲', [100, 200, 300, 400, 500, 600, 0, 0, 0, 0, 0, 0], 2025),
      _product('产品乙', [10, 20, 30, 40, 50, 60, 0, 0, 0, 0, 0, 0], 2025),
    ]);
    // Navigate to 2025 so the full 12-month window is shown.
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();

    final name = find.text('产品甲');
    expect(name, findsOneWidget);
    final nameBefore = tester.getTopLeft(name);
    final headerBefore = tester.getTopLeft(find.text('1月'));
    final cellBefore = tester.getTopLeft(find.text('+1.0%'));

    final gridScroll = find
        .ancestor(
          of: find.text('+1.0%'),
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    await tester.drag(gridScroll, const Offset(-200, 0));
    await tester.pumpAndSettle();

    // The product name did not move.
    expect(tester.getTopLeft(name), nameBefore);
    // The grid scrolled left ...
    final cellAfter = tester.getTopLeft(find.text('+1.0%'));
    expect(cellAfter.dx, lessThan(cellBefore.dx - 100));
    // ... and the month header followed it.
    final headerAfter = tester.getTopLeft(find.text('1月'));
    expect(headerAfter.dx, lessThan(headerBefore.dx - 100));
  });

  testWidgets('month header stays pinned while rows scroll vertically',
      (tester) async {
    // Distinct yearly rates keep the row order deterministic (desc).
    final products = List.generate(
      25,
      (i) => _product('产品${i + 1}', [
        100 * (i + 1),
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0
      ], 2025),
    );
    await _pump(tester, products);
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();

    final headerBefore = tester.getTopLeft(find.text('1月'));
    final firstRow = find.text('产品25');
    expect(firstRow, findsOneWidget);
    final firstRowBefore = tester.getTopLeft(firstRow);
    expect(firstRowBefore.dy, greaterThan(headerBefore.dy));

    final vScroll = find
        .ancestor(of: firstRow, matching: find.byType(SingleChildScrollView))
        .first;
    final vTopLeft = tester.getTopLeft(vScroll);
    await tester.dragFrom(
      vTopLeft + const Offset(40, 30),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();

    // The header stayed put ...
    expect(tester.getTopLeft(find.text('1月')), headerBefore);
    // ... while the rows scrolled up.
    final firstRowAfter = tester.getTopLeft(firstRow);
    expect(firstRowAfter.dy, lessThan(firstRowBefore.dy - 100));
  });

  testWidgets('dragging the month header scrolls the grid horizontally',
      (tester) async {
    await _pump(tester, [
      _product('产品甲', [100, 200, 300, 400, 500, 600, 0, 0, 0, 0, 0, 0], 2025),
      _product('产品乙', [10, 20, 30, 40, 50, 60, 0, 0, 0, 0, 0, 0], 2025),
    ]);
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();

    final headerScroll = find
        .ancestor(of: find.text('1月'), matching: find.byType(SingleChildScrollView))
        .first;
    final cellBefore = tester.getTopLeft(find.text('+1.0%'));

    await tester.drag(headerScroll, const Offset(-150, 0));
    await tester.pumpAndSettle();

    final cellAfter = tester.getTopLeft(find.text('+1.0%'));
    expect(cellAfter.dx, lessThan(cellBefore.dx - 50));
  });

  testWidgets('month view lists products of the selected month', (tester) async {
    await _pump(tester, [
      _product('产品甲', [100, 200, 300, 400, 500, 600, 0, 0, 0, 0, 0, 0], 2025),
      _product('产品乙', [10, 20, 30, 40, 50, 60, 0, 0, 0, 0, 0, 0], 2025),
    ]);
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('月', findRichText: true).last);
    await tester.pumpAndSettle();

    expect(find.text('产品甲'), findsOneWidget);
    expect(find.text('产品乙'), findsOneWidget);
  });
}
