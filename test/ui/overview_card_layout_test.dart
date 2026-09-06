import 'package:asset_tracker/ui/components/asset_overview_card.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies AssetOverviewCard renders 2x2 on phone (360px) and 4-in-a-row
/// on desktop (1280px).
void main() {
  testWidgets('phone 360px: 2x2 grid (2 rows)', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
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

    // Count the number of Rows inside the card (each row = one horizontal line of cells).
    final rows = tester.widgetList<Row>(find.byType(Row));
    debugPrint('PHONE 360px: found ${rows.length} Row widgets');
    expect(rows.length, 2, reason: 'Phone should render 2 rows (2x2 grid)');
  });

  testWidgets('desktop 1280px: 4-in-a-row (1 row)', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
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

    final rows = tester.widgetList<Row>(find.byType(Row));
    debugPrint('DESKTOP 1280px: found ${rows.length} Row widgets');
    expect(rows.length, 1, reason: 'Desktop should render 1 row (4 columns)');
  });
}
