import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/alerts/alerts_page.dart';
import 'package:asset_tracker/ui/pages/settings/settings_page.dart';
import 'package:asset_tracker/ui/shell/shell_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('notification settings return to alerts and then the original page', (tester) async {
    tester.view.physicalSize = const Size(390, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    final router = GoRouter(initialLocation: '/holdings', routes: [
      ShellRoute(
        builder: (context, state, child) => ShellPage(child: child),
        routes: [
          GoRoute(path: '/portfolio', builder: (_, _) => const Scaffold(body: Text('总览'))),
          GoRoute(path: '/holdings', builder: (context, _) => Scaffold(
            body: TextButton(onPressed: () => context.push('/alerts'), child: const Text('打开提醒')),
          )),
          GoRoute(path: '/alerts', builder: (_, _) => const AlertsPage()),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
        ],
      ),
    ]);
    addTearDown(() async { router.dispose(); container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开提醒'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/alerts');
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.text('通知设置'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/settings');
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/alerts');
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/holdings');
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
