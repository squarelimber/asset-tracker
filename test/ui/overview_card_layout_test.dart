import 'package:asset_tracker/ui/components/asset_overview_card.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies AssetOverviewCard renders 2x2 on phone (360px) and 4-in-a-row
/// on desktop (1280px).
///
/// Each cell is a Padding inside an Expanded inside a Row, so the cell
/// count of a row is the number of Expanded children of that Row. The
/// regression this guards: an inverted chunking ternary rendered
/// [row1: 4 cells, row2: 2 duplicated cells] on phone while still
/// producing exactly 2 Row widgets.
void main() {
  Future<void> pumpCard(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: AssetOverviewCard(
            totalAssets: 1865792.20,
            totalLiabilities: 3198.40,
            netWorth: 1862593.80,
            todayProfit: 1.14,
            todayPct: 0.0001,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The Row containing the cell with [label].
  ///
  /// Returns the first (outermost, i.e. grid) Row in tree order whose
  /// subtree contains the label.
  Row rowOf(WidgetTester tester, String label) {
    for (final row in tester.widgetList<Row>(find.byType(Row))) {
      final inside = tester.widgetList<Widget>(
        find.descendant(of: find.byWidget(row), matching: find.text(label)),
      );
      if (inside.isNotEmpty) return row;
    }
    fail('no Row contains $label');
  }

  int cellCount(WidgetTester tester, String label) =>
      rowOf(tester, label).children.whereType<Expanded>().length;

  testWidgets('phone 360px: 2x2 grid (2 rows of 2 cells)', (tester) async {
    await pumpCard(tester, const Size(360, 640));

    final rows = tester.widgetList<Row>(find.byType(Row));
    expect(rows.length, 2, reason: 'Phone should render 2 rows (2x2 grid)');

    // Every label appears exactly once (no duplicated cells).
    for (final label in ['总资产', '总负债', '净资产', '今日盈亏']) {
      expect(find.text(label), findsOneWidget, reason: '$label duplicated');
    }

    // Row 1: 总资产 + 总负债; Row 2: 净资产 + 今日盈亏 — two cells each.
    expect(cellCount(tester, '总资产'), 2);
    expect(cellCount(tester, '总负债'), 2);
    expect(cellCount(tester, '净资产'), 2);
    expect(cellCount(tester, '今日盈亏'), 2);
    expect(identical(rowOf(tester, '总资产'), rowOf(tester, '总负债')), isTrue,
        reason: '总资产 and 总负债 must share row 1');
    expect(identical(rowOf(tester, '净资产'), rowOf(tester, '今日盈亏')), isTrue,
        reason: '净资产 and 今日盈亏 must share row 2');
    expect(identical(rowOf(tester, '总资产'), rowOf(tester, '净资产')), isFalse,
        reason: 'row 1 and row 2 must be distinct Rows');
  });

  testWidgets('desktop 1280px: 4-in-a-row (1 row of 4 cells)', (tester) async {
    await pumpCard(tester, const Size(1280, 800));

    final rows = tester.widgetList<Row>(find.byType(Row));
    expect(rows.length, 1, reason: 'Desktop should render 1 row (4 columns)');

    for (final label in ['总资产', '总负债', '净资产', '今日盈亏']) {
      expect(find.text(label), findsOneWidget, reason: '$label duplicated');
      expect(cellCount(tester, label), 4);
    }
    expect(identical(rowOf(tester, '总资产'), rowOf(tester, '今日盈亏')), isTrue,
        reason: 'all four cells must share the single row');
  });
}
