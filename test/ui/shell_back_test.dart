import 'package:asset_tracker/ui/shell/shell_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  Widget app(GoRouter router) => MaterialApp.router(routerConfig: router);

  GoRouter buildRouter() {
    return GoRouter(
      initialLocation: '/portfolio',
      routes: [
        ShellRoute(
          builder: (context, state, child) => ShellPage(child: child),
          routes: [
            GoRoute(
              path: '/portfolio',
              builder: (_, _) => const SizedBox(),
            ),
            GoRoute(
              path: '/transactions',
              builder: (_, _) => const SizedBox(),
            ),
          ],
        ),
      ],
    );
  }

  bool shellCanPop(WidgetTester tester) => tester
      .widget<PopScope>(find.descendant(
        of: find.byType(ShellPage),
        matching: find.byType(PopScope),
      ))
      .canPop;

  testWidgets('root page may pop (back gesture exits the app)',
      (tester) async {
    await tester.pumpWidget(app(buildRouter()));
    await tester.pumpAndSettle();

    // On 总览 the back gesture should be allowed to pop (system exits app).
    expect(shellCanPop(tester), isTrue);
  });

  testWidgets('shell-level pages block pop so back returns to overview',
      (tester) async {
    final router = buildRouter();
    await tester.pumpWidget(app(router));
    await tester.pumpAndSettle();

    router.go('/transactions');
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/transactions');

    // Simulate the Android system back gesture: on a shell-level page with
    // no back stack the PopScope must intercept it (canPop false) and the
    // onPopInvoked handler redirects to 总览.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/portfolio');
  });

  testWidgets('root page back gesture is not redirected', (tester) async {
    final router = buildRouter();
    await tester.pumpWidget(app(router));
    await tester.pumpAndSettle();

    // A back gesture on 总览 must not be intercepted-and-redirected; it is
    // left to the system (exits the app). Nothing to assert on the no-op
    // SystemNavigator in tests, but the route must stay /portfolio and no
    // redirect (which would also land on /portfolio) can be distinguished —
    // so assert the PopScope widget flag directly instead.
    final pops = find.descendant(
      of: find.byType(ShellPage),
      matching: find.byType(PopScope),
    );
    expect(tester.widget<PopScope>(pops).canPop, isTrue);
  });
}