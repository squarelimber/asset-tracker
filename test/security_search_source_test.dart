import 'dart:convert';

import 'package:asset_tracker/services/market/security_search_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('解析 A 股、港股、美股和 ETF，保留美股交易所后缀', () async {
    Uri? requested;
    final client = MockClient((request) async {
      requested = request.url;
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'code': 0,
            'data': {
              'stock': [
                ['sh', '600519', '贵州茅台', '', 'GP-A'],
                ['sh', '510300', '沪深300ETF', '', 'ETF'],
                ['bj', '920799', '艾融软件', '', 'GP'],
                ['bj', '830799', '艾融软件旧代码', '', 'GP'],
                ['bj', '899999', '未映射证券', '', 'GP'],
                ['hk', '00700', '腾讯控股', '', 'GP'],
                ['hk', '02800', '盈富基金', '', 'GP-FUND'],
                ['hk', '00823', '领展房产基金', '', 'GP-FUND-REITS'],
                ['sz', '161725', '白酒基金LOF', '', 'LOF'],
                ['us', 'AAPL.OQ', '苹果', '', 'GP'],
                ['us', 'BRK.B.N', '伯克希尔B', '', 'GP'],
                ['us', 'SPY.AM', '标普ETF', '', 'GP-ETF'],
                ['jj', '00700', '场外基金', '', 'KJ'],
                ['sh', '600519', '贵州茅台', '', 'GP-A'],
                ['hk', 'oops', '无效代码', '', 'GP'],
                ['us', 'bad&query=x', '无效代码', '', 'GP'],
              ],
            },
          }),
        ),
        200,
      );
    });
    addTearDown(client.close);
    final source = SecuritySearchSource(client: client);
    final results = await source.search('  茅台  ');
    expect(requested!.queryParameters['q'], '茅台');
    expect(results.map((r) => r.symbol), [
      'sh600519',
      'sh510300',
      'bj920799',
      'hk00700',
      'hk02800',
      'usAAPL.OQ',
      'usBRK.B.N',
      'usSPY.AM',
    ]);
    expect(results.map((r) => r.market), [
      'A股',
      'A股',
      'A股',
      '港股',
      '港股',
      '美股',
      '美股',
      '美股',
    ]);
    expect(results.where((r) => r.type == 'ETF').map((r) => r.symbol), [
      'sh510300',
      'hk02800',
      'usSPY.AM',
    ]);
    source.close();
  });

  test('空查询不请求网络，接口失败与无结果分开', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (request.url.queryParameters['q'] == 'fail') {
        return http.Response('unavailable', 503);
      }
      return http.Response('{"code":0,"data":{"stock":[]}}', 200);
    });
    addTearDown(client.close);
    final source = SecuritySearchSource(client: client);
    expect(await source.search(' '), isEmpty);
    expect(calls, 0);
    expect(await source.search('unknown'), isEmpty);
    await expectLater(
      source.search('fail'),
      throwsA(isA<SecuritySearchException>()),
    );
    source.close();
  });

  test('北交所旧代码使用官方映射返回新代码', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      final rows = [
        ['bj', '430047', '诺思兰德', '', 'GP'],
      ];
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'code': 0,
            'data': {'stock': rows},
          }),
        ),
        200,
      );
    });
    addTearDown(client.close);
    final source = SecuritySearchSource(client: client);
    expect((await source.search('430047')).map((r) => r.symbol), ['bj920047']);
    expect(calls, 1);
  });
}
