import 'dart:convert';

import 'package:asset_tracker/services/market/kline_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('美股裸代码先解析交易所后缀再读取完整历史', () async {
    final urls = <Uri>[];
    final client = MockClient((request) async {
      urls.add(request.url);
      if (request.url.host == 'qt.gtimg.cn') {
        return http.Response('v_usAAPL="51~Apple~AAPL.OQ~200";', 200);
      }
      expect(request.url.queryParameters['param'], 'usAAPL.OQ,day,,,300,bfq');
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
    final bars = await KlineSource(
      client: client,
    ).fetch('usAAPL', KlinePeriod.day, adjusted: false);
    expect(urls.length, 2);
    expect(bars.single.close, 201);
    client.close();
  });

  test('无法确认美股交易所时不展示可能过期的历史', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('v_usAAPL="51~Other~MSFT.OQ~200";', 200);
    });
    final bars = await KlineSource(
      client: client,
    ).fetch('usAAPL', KlinePeriod.day);
    expect(bars, isEmpty);
    expect(requests, 1);
    client.close();
  });

  test('已有美股交易所后缀时直接读取历史', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'proxy.finance.qq.com');
      expect(request.url.queryParameters['param'], 'usSPY.AM,week,,,300,qfq');
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'usSPY.AM': {
              'week': [
                ['2026-11-06', '600', '601', '602', '599', '100'],
              ],
            },
          },
        }),
        200,
      );
    });
    final bars = await KlineSource(
      client: client,
    ).fetch('usSPY.AM', KlinePeriod.week);
    expect(bars.single.close, 601);
    client.close();
  });

  test('美股场外 PS 后缀可直接读取历史', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'proxy.finance.qq.com');
      expect(request.url.queryParameters['param'], 'usBABAF.PS,day,,,300,qfq');
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'usBABAF.PS': {
              'day': [
                ['2026-11-10', '10', '11', '12', '9', '100'],
              ],
            },
          },
        }),
        200,
      );
    });
    final bars = await KlineSource(
      client: client,
    ).fetch('usBABAF.PS', KlinePeriod.day);
    expect(bars.single.close, 11);
    client.close();
  });

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

  test('不复权模式请求并读取原始价格，不回退至复权数据', () async {
    final client = MockClient((request) async {
      expect(request.url.queryParameters['param'], 'sh510300,day,,,300,bfq');
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'sh510300': {
              'day': [
                ['2026-01-02', '3.8', '4.0', '4.1', '3.7', '100'],
              ],
              'qfqday': [
                ['2026-01-02', '1.8', '2.0', '2.1', '1.7', '100'],
              ],
            },
          },
        }),
        200,
      );
    });
    final source = KlineSource(client: client);
    final bars = await source.fetch(
      'sh510300',
      KlinePeriod.day,
      adjusted: false,
    );
    expect(bars.single.close, 4.0);
    client.close();
  });

  test('不复权模式拒绝仅有复权数据的响应', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'sh510300': {
              'qfqday': [
                ['2026-01-02', '1.8', '2.0', '2.1', '1.7', '100'],
              ],
            },
          },
        }),
        200,
      );
    });
    final bars = await KlineSource(
      client: client,
    ).fetch('sh510300', KlinePeriod.day, adjusted: false);
    expect(bars, isEmpty);
    expect(requests, 3);
    client.close();
  });
}
