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
    test('parses push2 NAV payload (scaled fields)', () async {
      const body = '{"rc":0,"data":{"f43":577,"f57":"161725",'
          '"f58":"BLSM","f169":12,"f170":212}}';
      final client = MockClient((req) async {
        expect(req.url.queryParameters['secid'], '0.161725');
        return http.Response(body, 200);
      });
      final source = EastmoneyFundQuoteSource(client: client);
      final quotes = await source.fetch(['161725']);

      final q = quotes.single;
      expect(q.isSuccess, isTrue);
      expect(q.symbol, '161725');
      expect(q.price, closeTo(0.577, 1e-9));
      expect(q.name, 'BLSM');
      expect(q.change, closeTo(0.012, 1e-9));
      expect(q.changePct, closeTo(0.0212, 1e-9));
      expect(q.prevClose, closeTo(0.565, 1e-9));
    });

    test('returns failure when data is absent', () async {
      final client = MockClient((req) async => http.Response('{"rc":100}', 200));
      final source = EastmoneyFundQuoteSource(client: client);
      expect((await source.fetch(['161725'])).single.isSuccess, isFalse);
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
  });
}
