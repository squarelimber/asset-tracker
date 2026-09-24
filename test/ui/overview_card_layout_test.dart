import 'package:asset_tracker/ui/components/asset_overview_card.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies AssetOverviewCard renders the bank-card hero layout on phone
/// (360px) and the 4-in-a-row grid on desktop (1280px).
///
/// Phone regression: the hero cell is 净资产 with the profit badge beside
/// the main value and a muted 总资产/负债 footer — the numbers must render
/// single-line (FittedBox scale-down), never wrapped/truncated.
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

  testWidgets('phone 360px: bank-card hero layout (净资产 + 盈亏标 + 底部小字)',
      (tester) async {
    await pumpCard(tester, const Size(360, 640));

    // Hero label exactly once.
    expect(find.text('净资产'), findsOneWidget);
    // Footer carries 总资产/负债 as one muted line.
    expect(find.textContaining('总资产'), findsOneWidget);
    expect(find.textContaining('负债'), findsOneWidget);
    // Profit badge next to the hero value: +¥1.14 (+0.01%).
    expect(find.textContaining('+'), findsOneWidget);

    // 主数值单行：无截断省略号。
    expect(find.text('1,862,593.80'), findsOneWidget);
  });

  testWidgets('phone: eye toggle inside the card, height stable with/without mask',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var toggles = 0;
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
            hidden: false,
            onToggleHidden: () => toggles++,
          ),
        ),
      ),
    );
    await tester.pump();

    // 眼睛按钮在卡片内。
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    expect(toggles, 1, reason: '点击眼睛应触发切换回调');

    // 卡片根 Container（渐变卡面）——隐私切换前后整体高度必须稳定。
    Finder cardRoot() => find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).gradient != null);
    final shownH = tester.getSize(cardRoot()).height;

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
            hidden: true,
            onToggleHidden: () => toggles++,
          ),
        ),
      ),
    );
    await tester.pump();

    // 隐藏后显示掩码，卡片高度应保持不变（不再“一会儿大一会儿小”）。
    expect(find.text('¥•••••'), findsOneWidget);
    expect(tester.getSize(cardRoot()).height, shownH,
        reason: '隐私切换不应改变卡片高度');
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