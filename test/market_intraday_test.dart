import 'dart:convert';

import 'package:asset_tracker/services/market/kline_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('读取有色 ETF 的日期和有效分时价，接口失败时切换备用源', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (requests.length == 1) return http.Response('', 503);
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'sz159980': {
              'qt': {
                'sz159980': ['51', 'ETF', '159980', '2.004', '1.960'],
              },
              'data': {
                'date': '20261118',
                'data': [
                  '0931 2.004 900',
                  '0930 1.999 23',
                  '1159 NaN',
                  '0999 2.5',
                  '1700 2',
                ],
              },
            },
          },
        }),
        200,
      );
    });
    addTearDown(client.close);
    final series = await KlineSource(client: client).fetchIntraday('sz159980');
    expect(series?.date, '2026-11-18');
    expect(series?.previousClose, 1.960);
    expect(series?.points, [
      (minute: 570, value: 1.999),
      (minute: 571, value: 2.004),
    ]);
    expect(
      requests.every((url) => url.queryParameters['code'] == 'sz159980'),
      isTrue,
    );
    expect(requests, hasLength(2));
  });
}
