import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:asset_tracker/services/market/eastmoney_fund_quote_source.dart';
import 'package:asset_tracker/services/market/tencent_history_source.dart';
import 'package:asset_tracker/services/market/tencent_quote_source.dart';

/// Byte-preserving body helper: ASCII fields survive 1:1, Chinese fields
/// may garble (they are never read by the parsers).
List<int> asciiBytes(String s) => s.codeUnits.map((c) => c).toList();

void main() {
  group('TencentQuoteSource', () {
    test('parses A-share quote (tilde-separated fields)', () async {
      final fields = List.filled(35, '0');
      fields[0] = '1';
      fields[1] = 'MAOTAI';
      fields[2] = '600519';
      fields[3] = '1348.86';
      fields[4] = '1309.22';
      fields[30] = '20260810161456';
      fields[31] = '39.64';
      fields[32] = '3.03';
      fields[33] = '1350.00';
      fields[34] = '1290.00';
      final client = MockClient((req) async {
        expect(req.url.path, '/q=sh600519');
        return http.Response.bytes(
          asciiBytes('v_sh600519="${fields.join('~')}";'),
          200,
        );
      });
      final source = TencentQuoteSource(client: client);
      final quotes = await source.fetch(['sh600519']);

      expect(quotes, hasLength(1));
      final q = quotes.single;
      expect(q.isSuccess, isTrue);
      expect(q.symbol, 'sh600519');
      expect(q.price, 1348.86);
      expect(q.prevClose, 1309.22);
      expect(q.change, 39.64);
      expect(q.changePct, closeTo(0.0303, 1e-9));
    });

    test('parses offshore commodity hf_XAU (comma-separated)', () async {
      const body = 'v_hf_XAU="4347.69,0.15,4347.69,4348.04,4361.80,4313.27,'
          '22:48:00,4341.12,4346.54,0,0,0,2026-08-10,GOLD";';
      final client = MockClient((req) async =>
          http.Response.bytes(asciiBytes(body), 200));
      final source = TencentQuoteSource(client: client);
      final quotes = await source.fetch(['hf_XAU']);

      final q = quotes.single;
      expect(q.isSuccess, isTrue);
      expect(q.price, 4347.69);
      expect(q.prevClose, 4341.12);
      expect(q.change, closeTo(6.57, 1e-9));
      expect(q.changePct, closeTo(0.0015, 1e-9));
    });

    test('parses FX quote and maps currency codes back', () async {
      const body = 'v_whUSDCNY="310~USDCNY~USDCNY~6.7452~0~20260810225302~'
          '6.7453~6.7462~6.7471~6.7431~6.7452~6.7459~-0.0001~-0.00~-0.14";';
      final client = MockClient((req) async {
        expect(req.url.path, '/q=whUSDCNY');
        return http.Response.bytes(asciiBytes(body), 200);
      });
      final source = TencentQuoteSource(client: client);
      final quotes = await source.fetch(['USD']);

      final q = quotes.single;
      expect(q.isSuccess, isTrue);
      expect(q.symbol, 'USD');
      expect(q.price, 6.7452);
      expect(q.prevClose, 6.7453);
      expect(q.change, -0.0001);
      expect(q.changePct, closeTo(0.0, 1e-9));
    });

    test('maps gold aliases to hf_XAU and restores the symbol', () async {
      const body = 'v_hf_XAU="4347.69,0.15,4347.69,4348.04,4361.80,4313.27,'
          '22:48:00,4341.12,4346.54,0,0,0,2026-08-10,GOLD";';
      final client = MockClient((req) async {
        expect(req.url.path, '/q=hf_XAU');
        return http.Response.bytes(asciiBytes(body), 200);
      });
      final source = TencentQuoteSource(client: client);
      final quotes = await source.fetch(['AU99.99']);

      final q = quotes.single;
      expect(q.isSuccess, isTrue);
      expect(q.symbol, 'AU99.99');
      expect(q.price, 4347.69);
    });
  });

  group('TencentGoldFxAdapter', () {
    test('converts gold USD/oz to CNY/gram using the USD rate', () async {
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/q=hf_XAU,whUSDCNY') {
          return http.Response.bytes(
            asciiBytes('v_hf_XAU="4347.69,0.15,4347.69,4348.04,4361.80,'
                '4313.27,22:48:00,4341.12,4346.54,0,0,0,2026-08-10,GOLD";'
                'v_whUSDCNY="310~USDCNY~USDCNY~6.7452~0~20260810225302~'
                '6.7453~6.7462~6.7471~6.7431~6.7452~6.7459~-0.0001~-0.00";'),
            200,
          );
        }
        if (path == '/q=whUSDCNY') {
          return http.Response.bytes(
            asciiBytes('v_whUSDCNY="310~USDCNY~USDCNY~6.7452~0~20260810225302~'
                '6.7453~6.7462~6.7471~6.7431~6.7452~6.7459~-0.0001~-0.00";'),
            200,
          );
        }
        return http.Response('unexpected: $path', 404);
      });
      final source = TencentGoldFxAdapter(client: client);
      final quotes = await source.fetch(['XAU']);

      final q = quotes.single;
      expect(q.isSuccess, isTrue);
      expect(q.symbol, 'XAU');
      expect(q.price, closeTo(4347.69 * 6.7452 / 31.1034768, 0.01));
      expect(q.prevClose, closeTo(4341.12 * 6.7452 / 31.1034768, 0.01));
    });
  });

  group('EastmoneyFundQuoteSource', () {
    test('queries the fund-only mobile API and parses the NAV row', () async {
      const body = '{"Datas":[{"FCODE":"400030","SHORTNAME":"\u4e1c\u65b9\u6dfb\u76ca\u503a\u5238",'
          '"PDATE":"2026-10-08","NAV":"1.4553","NAVCHGRT":"-2.07"}],'
          '"ErrCode":0,"Success":true,"TotalCount":1}';
      final client = MockClient((req) async {
        expect(req.url.host, 'fundmobapi.eastmoney.com');
        expect(req.url.path, '/FundMNewApi/FundMNFInfo');
        expect(req.url.queryParameters['FCODES'], '400030');
        expect(req.url.queryParameters['plat'], 'Wap');
        return http.Response.bytes(utf8.encode(body), 200);
      });
      final source = EastmoneyFundQuoteSource(client: client);
      final quotes = await source.fetch(['400030']);

      final q = quotes.single;
      expect(q.isSuccess, isTrue);
      expect(q.symbol, '400030');
      expect(q.price, closeTo(1.4553, 1e-9));
      expect(q.name, '东方添益债券');
      expect(q.changePct, closeTo(-0.0207, 1e-9));
      expect(q.prevClose, closeTo(1.4553 / (1 - 0.0207), 1e-6));
    });

    test('never asks the stock endpoint for a fund code', () async {
      // Regression: push2's *stock* endpoint answers 400030 with the
      // unrelated third-board stock 蓝璟5 (0.063) instead of the fund NAV
      // (1.4553). The fund source must only ever talk to the fund API.
      final client = MockClient((req) async {
        expect(req.url.host, isNot('push2.eastmoney.com'));
        return http.Response.bytes(utf8.encode('{"Datas":null}'), 200);
      });
      final source = EastmoneyFundQuoteSource(client: client);
      await source.fetch(['400030']);
    });

    test('returns failure for a code missing from Datas', () async {
      final client = MockClient((req) async =>
          http.Response.bytes(utf8.encode('{"Datas":null,"ErrCode":0}'), 200));
      final source = EastmoneyFundQuoteSource(client: client);
      expect((await source.fetch(['999999'])).single.isSuccess, isFalse);
    });

    test('batches every code into a single request', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        expect(req.url.queryParameters['FCODES'], '400030,002943');
        return http.Response.bytes(
          utf8.encode('{"Datas":['
              '{"FCODE":"400030","SHORTNAME":"A","NAV":"1.4553","NAVCHGRT":"0.00"},'
              '{"FCODE":"002943","SHORTNAME":"B","NAV":"4.6809","NAVCHGRT":"-2.07"}]}'),
          200,
        );
      });
      final source = EastmoneyFundQuoteSource(client: client);
      final quotes = await source.fetch(['400030', '002943']);
      expect(calls, 1);
      expect(quotes.map((q) => q.price),
          [closeTo(1.4553, 1e-9), closeTo(4.6809, 1e-9)]);
    });
  });

  group('TencentHistorySource', () {
    test('parses qfqday rows into date->close map', () async {
      const body = '{"code":0,"data":{"sh000001":{"qfqday":['
          '["2026-08-06","25667.14","25530.28","25667.14","25389.42","1000"],'
          '["2026-08-07","25600.00","25700.00","25710.00","25550.00","2000"],'
          '["2026-08-10","25650.00","25450.00","25680.00","25400.00","1500"]'
          ']}}}';
      final client = MockClient((req) async => http.Response(body, 200));
      final source = TencentHistorySource(client: client);
      final from = DateTime(2026, 8, 1);
      final to = DateTime(2026, 8, 11);
      final history = await source.fetch('sh000001', from, to);

      expect(history['2026-08-06'], 25530.28);
      expect(history['2026-08-07'], 25700.00);
      expect(history['2026-08-10'], 25450.00);
      expect(history, hasLength(3));
    });

    test('filters rows outside the requested window', () async {
      const body = '{"code":0,"data":{"sh000001":{"qfqday":['
          '["2026-07-01","100.0","100.0","100.0","100.0","1"],'
          '["2026-08-06","101.0","101.0","101.0","101.0","1"],'
          '["2026-09-01","102.0","102.0","102.0","102.0","1"]'
          ']}}}';
      final client = MockClient((req) async => http.Response(body, 200));
      final source = TencentHistorySource(client: client);
      final history = await source.fetch(
          'sh000001', DateTime(2026, 8, 1), DateTime(2026, 8, 31));
      expect(history, hasLength(1));
      expect(history['2026-08-06'], 101.0);
    });

    test('queries the proxy gateway first (both ifzq hosts are WAF-blocked)',
        () async {
      // `/appstock/app/fqkline/get` on `web.ifzq.gtimg.cn` has been answering
      // a 501 JS challenge since ~2026-10-08, and by 2026-10-09 the bare
      // `ifzq.gtimg.cn` host was blocked too — so the `proxy.finance.qq.com`
      // gateway, which serves the same qfq-adjusted `qfqday` payload under a
      // different path, must be the primary endpoint.
      const body = '{"code":0,"data":{"sh512480":{"qfqday":[]}}}';
      late Uri seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response.bytes(asciiBytes(body), 200);
      });
      final source = TencentHistorySource(client: client);
      await source.fetch('sh512480', DateTime(2026, 9, 20), DateTime(2026, 10, 8));

      expect(seen.host, 'proxy.finance.qq.com');
      expect(seen.path, '/ifzqgtimg/appstock/app/newfqkline/get');
      // 18 calendar days in the window, +20 rows of slack for week-long
      // holidays, qfq-adjusted.
      expect(seen.queryParameters['param'],
          'sh512480,day,2026-09-20,2026-10-08,38,qfq');
    });

    test('falls back to the next endpoint when the first one answers a WAF 501',
        () async {
      // A blocked endpoint must not silently end up as "this symbol has no
      // history": that empty series is what made the backfill price every
      // historical day from the current quote.
      const body = '{"code":0,"data":{"sh512480":{"qfqday":['
          '["2026-09-30","0.96","0.955","0.97","0.95","1000"]'
          ']}}}';
      final hosts = <String>[];
      final client = MockClient((req) async {
        hosts.add(req.url.host);
        if (req.url.host == 'proxy.finance.qq.com') {
          return http.Response('<!DOCTYPE html>waf', 501);
        }
        return http.Response.bytes(asciiBytes(body), 200);
      });
      final source = TencentHistorySource(client: client);
      final history = await source.fetch(
          'sh512480', DateTime(2026, 9, 20), DateTime(2026, 10, 8));

      expect(hosts, ['proxy.finance.qq.com', 'ifzq.gtimg.cn']);
      expect(history['2026-09-30'], 0.955);
    });
  });
}
