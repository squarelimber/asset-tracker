import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:asset_tracker/services/market/eastmoney_source.dart';
import 'package:asset_tracker/services/market/sina_source.dart';

void main() {
  group('SinaSource', () {
    test('parses A-share quote fields (ASCII-safe)', () async {
      const body = 'var hq_str_sh600519="贵州茅台,1700.00,1680.00,1690.00,1710.00,1720.00,'
          '1680.00,1690.00,200000,100000,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,'
          '2026-08-08,15:00:00,00";';
      final client = MockClient((req) async => http.Response.bytes(
            body.codeUnits.map((c) => c).toList(),
            200,
          ));
      final source = SinaSource(client: client);
      final quotes = await source.fetch(['sh600519']);

      expect(quotes, hasLength(1));
      final q = quotes.single;
      expect(q.isSuccess, isTrue);
      expect(q.price, 1690.00);
      expect(q.prevClose, 1680.00);
      expect(q.changePct, closeTo(0.005952, 0.000001));
    });

    test('returns failure for empty/invalid symbol', () async {
      const body = 'var hq_str_sz000001="";';
      final client = MockClient((req) async => http.Response.bytes(
            body.codeUnits.map((c) => c).toList(),
            200,
          ));
      final source = SinaSource(client: client);
      final quotes = await source.fetch(['sz000001']);
      expect(quotes.single.isSuccess, isFalse);
    });
  });

  group('EastmoneySource', () {
    test('parses official NAV payload', () async {
      const body = '{"Data":{"LSJZList":[{"FSRQ":"2026-08-07","DWJZ":"2.9220",'
          '"JZZZL":"-0.17"}],"FundType":"001"},"ErrCode":0,"TotalCount":3860}';
      final client = MockClient((req) async => http.Response.bytes(
            utf8.encode(body),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final source = EastmoneySource(client: client);
      final quotes = await source.fetch(['110022']);

      expect(quotes, hasLength(1));
      final q = quotes.single;
      expect(q.isSuccess, isTrue);
      expect(q.price, 2.922);
      expect(q.changePct, closeTo(-0.0017, 0.0000001));
      expect(q.prevClose, closeTo(2.926976, 0.0001));
    });

    test('returns failure on bad payload', () async {
      final client = MockClient((req) async => http.Response('not json', 200));
      final source = EastmoneySource(client: client);
      expect((await source.fetch(['110022'])).single.isSuccess, isFalse);
    });
  });
}
