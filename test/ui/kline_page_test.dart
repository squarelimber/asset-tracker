import 'dart:convert';

import 'package:asset_tracker/services/market/kline_source.dart';
import 'package:asset_tracker/ui/pages/markets/kline_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('K 线加载并切换指数和周期', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <String>[];
    final client = MockClient((request) async {
      final param = request.url.queryParameters['param']!;
      requests.add(param);
      final parts = param.split(',');
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            parts[0]: {
              parts[1]: [
                ['2026-11-06', '3300', '3330', '3340', '3290', '50000'],
                ['2026-11-09', '3330', '3350', '3360', '3320', '60000'],
              ],
            },
          },
        }),
        200,
      );
    });
    addTearDown(client.close);
    await tester.pumpWidget(
      MaterialApp(
        home: KlinePage(source: KlineSource(client: client)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('最新 K 线'), findsOneWidget);
    expect(find.textContaining('2026-11-09'), findsWidgets);
    expect(requests.last, startsWith('sh000001,day,'));

    await tester.tap(find.text('周 K'));
    await tester.pumpAndSettle();
    expect(requests.last, startsWith('sh000001,week,'));
    await tester.tap(find.text('创业板指'));
    await tester.pumpAndSettle();
    expect(requests.last, startsWith('sz399006,week,'));
    expect(tester.takeException(), isNull);
  });
}
