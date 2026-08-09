import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:asset_tracker/services/market/global_quote_source.dart';

GlobalQuoteSource _sourceWith(String body) {
  final client = MockClient((req) async => http.Response.bytes(
        latin1.encode(body),
        200,
      ));
  return GlobalQuoteSource(client: client);
}

void main() {
  test('parses A-share index quotes', () async {
    final source = _sourceWith('var hq_str_sh000001="SH,3800.0,3890.0,3896.0,3940.0,3885.0";');
    final quotes = await source.fetch();
    final sh = quotes.firstWhere((q) => q.code == 'sh000001');
    expect(sh.isSuccess, isTrue);
    expect(sh.price, 3896.0);
    expect(sh.change, closeTo(6.0, 1e-9));
    expect(sh.changePct, closeTo(6 / 3890, 1e-9));
  });

  test('parses HSI quotes (rt_hk prefix)', () async {
    final source = _sourceWith(
        'var hq_str_rt_hkHSI="HSI,HSI,25526.650,25530.279,25669.520,25393.130,25668.031,1";');
    final quotes = await source.fetch();
    final hsi = quotes.firstWhere((q) => q.code == 'rt_hkHSI');
    expect(hsi.price, 25526.65);
    expect(hsi.change, closeTo(25526.65 - 25668.031, 1e-9));
  });

  test('parses US index quotes (gb_ prefix)', () async {
    final source = _sourceWith(
        'var hq_str_gb_ixic="IXIC,26690.6150,1.30,2026-08-08 05:30:00,342.2628,26534.6603,26712.616";');
    final quotes = await source.fetch();
    final ix = quotes.firstWhere((q) => q.code == 'gb_ixic');
    expect(ix.price, 26690.615);
    expect(ix.change, closeTo(26690.615 - 26534.6603, 1e-9));
  });

  test('parses Nikkei (int_ prefix with change+pct fields)', () async {
    final source = _sourceWith('var hq_str_int_nikkei="N225,44946.64,-408.35,-0.90";');
    final quotes = await source.fetch();
    final nk = quotes.firstWhere((q) => q.code == 'int_nikkei');
    expect(nk.price, 44946.64);
    expect(nk.change, -408.35);
    expect(nk.changePct, -0.9);
  });

  test('parses commodity quotes (hf_ prefix)', () async {
    final source = _sourceWith(
        'var hq_str_hf_CL="77.031,,77.080,77.110,78.770,76.530,04:59:59,77.290,78.170";');
    final quotes = await source.fetch();
    final cl = quotes.firstWhere((q) => q.code == 'hf_CL');
    expect(cl.price, 77.031);
    expect(cl.change, closeTo(77.031 - 77.290, 1e-9));
    expect(cl.unit, '美元/桶');
  });

  test('parses FX mid price (fx_ prefix)', () async {
    final source = _sourceWith(
        'var hq_str_fx_susdcny="02:52:32,6.7372000000,6.7655000000,6.7513000000,171.0,6.7483000000,6.7513000000,6.7342000000,6.7513000000";');
    final quotes = await source.fetch();
    final usd = quotes.firstWhere((q) => q.code == 'fx_susdcny');
    expect(usd.price, 6.7513);
    expect(usd.fxSymbol, 'USD');
    expect(usd.change, closeTo(6.7513 - 6.7342, 1e-9));
  });

  test('all catalog codes parse or are skipped gracefully', () async {
    final source = _sourceWith(
        'var hq_str_sh000001="SH,3800.0,3890.0,3896.0,3940.0,3885.0";');
    final quotes = await source.fetch();
    // Only the provided symbol parses; others are skipped without error.
    expect(quotes.length, 1);
  });
}
