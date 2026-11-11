import 'dart:async';
import 'dart:convert';

import 'package:asset_tracker/services/market/security_search_source.dart';
import 'package:asset_tracker/ui/pages/markets/security_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response response(String code, String name) => http.Response.bytes(
  utf8.encode(
    jsonEncode({
      'code': 0,
      'data': {
        'stock': [
          ['sh', code, name, '', 'GP-A'],
        ],
      },
    }),
  ),
  200,
);

void main() {
  testWidgets('搜索结果可进入所选证券，较慢的旧请求不会覆盖新结果', (tester) async {
    final old = Completer<http.Response>();
    final client = MockClient((request) {
      return request.url.queryParameters['q'] == '旧'
          ? old.future
          : Future.value(response('600519', '贵州茅台'));
    });
    addTearDown(client.close);
    final source = SecuritySearchSource(client: client);
    final router = GoRouter(
      initialLocation: '/markets/search',
      routes: [
        GoRoute(
          path: '/markets/search',
          builder: (context, state) => SecuritySearchPage(source: source),
        ),
        GoRoute(
          path: '/markets/kline',
          builder: (_, state) => Scaffold(
            body: Text(
              '${state.uri.queryParameters['symbol']} ${state.uri.queryParameters['name']}',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.enterText(find.byType(TextField), '旧');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), '茅台');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('贵州茅台'), findsOneWidget);
    old.complete(response('600000', '旧结果'));
    await tester.pump();
    expect(find.text('旧结果'), findsNothing);
    await tester.tap(find.text('贵州茅台'));
    await tester.pumpAndSettle();
    expect(find.text('sh600519 贵州茅台'), findsOneWidget);
  });

  testWidgets('搜索失败可重试', (tester) async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return calls == 1
          ? http.Response('error', 500)
          : response('600519', '贵州茅台');
    });
    addTearDown(client.close);
    await tester.pumpWidget(
      MaterialApp(
        home: SecuritySearchPage(source: SecuritySearchSource(client: client)),
      ),
    );
    await tester.enterText(find.byType(TextField), '茅台');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('搜索失败，请检查网络后重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('贵州茅台'), findsOneWidget);
  });
}
