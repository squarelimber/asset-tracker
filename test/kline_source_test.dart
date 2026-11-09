import 'dart:convert';

import 'package:asset_tracker/services/market/kline_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('解析真实接口格式并按日期排列，跳过无效蜡烛', () async {
    final client = MockClient((request) async {
      expect(request.url.queryParameters['param'], 'sh510300,week,,,300,qfq');
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'sh510300': {
              'qfqweek': [
                ['2026-01-09', '4.0', '4.2', '4.3', '3.9', '123'],
                ['2026-01-02', '3.8', '4.0', '4.1', '3.7', '100'],
                ['2026-01-16', '4.1', '4.2', '4.0', '3.9', '100'],
              ],
            },
          },
        }),
        200,
      );
    });
    final bars = await KlineSource(
      client: client,
    ).fetch('sh510300', KlinePeriod.week);
    expect(bars.length, 2);
    expect(bars.first.date, DateTime(2026, 1, 2));
    expect(bars.last.close, 4.2);
    expect(bars.last.volume, 123);
  });

  test('主接口失败后回退到备用接口', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) return http.Response('unavailable', 503);
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'sh000001': {
              'day': [
                ['2026-01-02', '10', '11', '12', '9', '0'],
              ],
            },
          },
        }),
        200,
      );
    });
    final bars = await KlineSource(
      client: client,
    ).fetch('sh000001', KlinePeriod.day);
    expect(calls, 2);
    expect(bars.single.high, 12);
    expect(bars.single.volume, 0);
  });

  test('无数据和无效响应返回空列表', () async {
    final client = MockClient(
      (request) async => http.Response('not json', 200),
    );
    final bars = await KlineSource(
      client: client,
    ).fetch('missing', KlinePeriod.month);
    expect(bars, isEmpty);
  });
}
