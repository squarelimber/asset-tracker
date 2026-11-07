import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/ui/components/asset_overview_card.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_welcome.dart';
import 'package:asset_tracker/ui/shell/shell_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

GoRouter _router({bool hasAccounts = false}) => GoRouter(
  initialLocation: '/portfolio',
  routes: [
    ShellRoute(
      builder: (context, state, child) => ShellPage(child: child),
      routes: [
        GoRoute(
          path: '/portfolio',
          builder: (_, _) =>
              Scaffold(body: PortfolioWelcome(hasAccounts: hasAccounts)),
        ),
        for (final path in [
          'accounts',
          'holdings',
          'markets',
          'stats',
          'transactions',
          'alerts',
          'settings',
        ])
          GoRoute(
            path: '/$path',
            builder: (_, _) => Scaffold(body: Text('page:$path')),
          ),
      ],
    ),
  ],
);

void main() {
  testWidgets('desktop page shortcuts respect modals and modifier keys', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.dark(), routerConfig: router),
    );
    await tester.pumpAndSettle();

    for (final useRootNavigator in [true, false]) {
      final pageContext = tester.element(find.byType(PortfolioWelcome));
      showDialog<void>(
        context: pageContext,
        useRootNavigator: useRootNavigator,
        builder: (context) => AlertDialog(
          title: const Text('确认操作'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pumpAndSettle();
      expect(find.text('确认操作'), findsOneWidget);
      expect(find.text('page:holdings'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    }

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(PortfolioWelcome), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pumpAndSettle();
    expect(find.text('page:holdings'), findsOneWidget);
  });

  testWidgets('desktop secondary navigation selects only its own destination', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.dark(), routerConfig: router),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: find.byType(ListView), matching: find.text('交易流水')),
    );
    await tester.pumpAndSettle();
    expect(find.text('page:transactions'), findsOneWidget);
    final selected = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .where((widget) => widget.properties.selected == true);
    expect(selected, hasLength(1));
    expect(
      find.descendant(
        of: find.byWidget(selected.single),
        matching: find.text('交易流水'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(360, 640), const Size(1100, 600)]) {
    testWidgets(
      'welcome remains usable at $size and reuses existing accounts',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final router = _router(hasAccounts: true);
        addTearDown(router.dispose);
        await tester.pumpWidget(
          MaterialApp.router(theme: AppTheme.dark(), routerConfig: router),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final action = find.text('添加第一笔持仓');
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.text('page:holdings'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'desktop overview fits long amounts within the sidebar content area',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 700);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Row(
              children: [
                SizedBox(width: 192),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: AssetOverviewCard(
                      totalAssets: 1234567890.12,
                      totalLiabilities: 234567890.12,
                      netWorth: 1000000000,
                      todayProfit: 12345678.90,
                      todayPct: 0.0123,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('净资产'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
