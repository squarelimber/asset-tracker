import 'dart:convert';

import 'package:asset_tracker/services/market/kline_source.dart';
import 'package:asset_tracker/ui/pages/markets/kline_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('搜索到的证券保留代码和名称，不切换成指数', (tester) async {
    final requests = <String>[];
    final client = MockClient((request) async {
      final param = request.url.queryParameters['param']!;
      requests.add(param);
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'usAAPL.OQ': {
              'day': [
                ['2026-11-10', '200', '201', '202', '199', '100'],
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
        home: KlinePage(
          initialSymbol: 'usAAPL.OQ',
          initialName: '苹果',
          source: KlineSource(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('苹果'), findsOneWidget);
    expect(find.text('证券 K 线'), findsOneWidget);
    expect(requests.single, startsWith('usAAPL.OQ,day,'));
    expect(find.text('上证指数'), findsNothing);
  });

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
    expect(find.textContaining('最近 K 线'), findsOneWidget);
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
