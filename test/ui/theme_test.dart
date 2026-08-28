import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/components/app_bar_actions.dart';
import 'package:asset_tracker/ui/shell/shell_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('dark theme uses terminal tokens', () {
    final t = AppTheme.dark();
    expect(t.scaffoldBackgroundColor, const Color(0xFF0A0C0F));
    expect(t.appBarTheme.backgroundColor, const Color(0xFF0A0C0F));
    expect(t.colorScheme.primary, const Color(0xFF58A6FF));
    expect(t.cardTheme.color, const Color(0xFF12151A));
  });

  Future<void> pumpShell(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = GoRouter(
      initialLocation: '/portfolio',
      routes: [
        ShellRoute(
          builder: (context, state, child) => ShellPage(child: child),
          routes: [
            GoRoute(path: '/portfolio', builder: (_, _) => const Scaffold(body: Text('组合'))),
            GoRoute(path: '/holdings', builder: (_, _) => const Scaffold(body: Text('持仓'))),
            GoRoute(path: '/accounts', builder: (_, _) => const Scaffold(body: Text('账户'))),
            GoRoute(path: '/markets', builder: (_, _) => const Scaffold(body: Text('行情'))),
            GoRoute(path: '/stats', builder: (_, _) => const Scaffold(body: Text('统计'))),
            GoRoute(path: '/alerts', builder: (_, _) => const Scaffold(body: Text('提醒'))),
            GoRoute(path: '/settings', builder: (_, _) => const Scaffold(body: Text('设置'))),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(routerConfig: router, theme: AppTheme.dark()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('phone shell shows 5 bottom destinations', (tester) async {
    await pumpShell(tester, const Size(360, 640));
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final name in ['总览', '持仓', '账户', '行情', '统计']) {
      expect(find.text(name), findsWidgets, reason: 'missing $name');
    }
  });

  testWidgets('desktop shell shows 5 rail destinations', (tester) async {
    await pumpShell(tester, const Size(1400, 900));
    expect(find.byType(NavigationRail), findsOneWidget);
    for (final name in ['总览', '持仓', '账户', '行情', '统计']) {
      expect(find.text(name), findsWidgets, reason: 'missing $name');
    }
  });

  testWidgets('app bar actions show bell and gear', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          alertEventsProvider.overrideWith((ref) => Stream.value(const [])),
        ],
        child: MaterialApp(theme: AppTheme.dark(), home: const TerminalAppBarActions()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });
}
