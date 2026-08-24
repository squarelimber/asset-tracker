import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'market_data_source.dart';

/// One global market quote (index / commodity / FX).
class GlobalQuote {
  const GlobalQuote({
    required this.code,
    required this.name,
    required this.group,
    required this.price,
    required this.change,
    required this.changePct,
    this.unit,
    this.fxSymbol,
  });

  final String code;
  final String name;

  /// Display group: A股 / 亚太 / 欧美 / 大宗商品 / 货币.
  final String group;
  final double price;
  final double change;
  final double changePct;

  /// Unit suffix for commodities (e.g. 美元/盎司).
  final String? unit;

  /// Display symbol for FX quotes (e.g. USD).
  final String? fxSymbol;

  bool get isSuccess => price > 0;
}

/// Quote definitions (all served by Sina free endpoints).
class GlobalQuoteCatalog {
  const GlobalQuoteCatalog._();

  static const List<GlobalQuoteDef> items = [
    // A股
    GlobalQuoteDef('sh000001', '上证指数', 'A股', 'point'),
    GlobalQuoteDef('sz399001', '深证成指', 'A股', 'point'),
    GlobalQuoteDef('sz399006', '创业板指', 'A股', 'point'),
    // 亚太
    GlobalQuoteDef('rt_hkHSI', '恒生指数', '亚太', 'point'),
    GlobalQuoteDef('int_nikkei', '日经225', '亚太', 'point'),
    // 欧美
    GlobalQuoteDef(r'gb_$dji', '道琼斯', '欧美', 'point'),
    GlobalQuoteDef('gb_inx', '标普500', '欧美', 'point'),
    GlobalQuoteDef('gb_ixic', '纳斯达克', '欧美', 'point'),
    // 大宗商品
    GlobalQuoteDef('hf_XAU', '伦敦金', '大宗商品', '美元/盎司'),
    GlobalQuoteDef('hf_GC', '纽约金', '大宗商品', '美元/盎司'),
    GlobalQuoteDef('hf_CL', 'WTI原油', '大宗商品', '美元/桶'),
    GlobalQuoteDef('hf_OIL', '布伦特原油', '大宗商品', '美元/桶'),
    GlobalQuoteDef('hf_HG', '铜', '大宗商品', '美元/磅'),
    // 货币（兑人民币，美元显示中间价）
    GlobalQuoteDef('fx_susdcny', '美元人民币', '货币', null, fxSymbol: 'USD'),
    GlobalQuoteDef('fx_seurcny', '欧元人民币', '货币', null, fxSymbol: 'EUR'),
    GlobalQuoteDef('fx_shkdcny', '港币人民币', '货币', null, fxSymbol: 'HKD'),
    GlobalQuoteDef('fx_sgbpcny', '英镑人民币', '货币', null, fxSymbol: 'GBP'),
    GlobalQuoteDef('fx_sjpycny', '日元人民币', '货币', null, fxSymbol: 'JPY'),
    GlobalQuoteDef('fx_saudcny', '澳元人民币', '货币', null, fxSymbol: 'AUD'),
    GlobalQuoteDef('fx_scadcny', '加元人民币', '货币', null, fxSymbol: 'CAD'),
    GlobalQuoteDef('fx_schfcny', '瑞郎人民币', '货币', null, fxSymbol: 'CHF'),
  ];
}

class GlobalQuoteDef {
  const GlobalQuoteDef(this.code, this.name, this.group, this.unit, {this.fxSymbol});

  final String code;
  final String name;
  final String group;
  final String? unit;
  final String? fxSymbol;
}

/// Fetches global quotes from Sina in one batched request.
/// Field layouts differ per code prefix; see [_parse] for details.
class GlobalQuoteSource {
  GlobalQuoteSource({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _base = 'https://hq.sinajs.cn/list=';

  Future<List<GlobalQuote>> fetch() async {
    if (kIsWeb) return _fetchTencent();
    final codes = [for (final d in GlobalQuoteCatalog.items) d.code];
    final results = <GlobalQuote>[];
    try {
      final resp = await _client
          .get(Uri.parse('$_base${codes.join(',')}'),
              headers: {'Referer': 'https://finance.sina.com.cn'})
          .timeout(marketHttpTimeout);
      if (resp.statusCode != 200) return results;
      // ASCII fields are preserved by latin1 passthrough; Chinese names are
      // provided by our own catalog instead of the (GBK) response.
      final text = latin1.decode(resp.bodyBytes, allowInvalid: true);
      final map = _parseRaw(text);
      for (final def in GlobalQuoteCatalog.items) {
        final fields = map[def.code];
        if (fields == null || fields.isEmpty) continue;
        final parsed = _parseQuote(def, fields);
        if (parsed != null) results.add(parsed);
      }
    } catch (_) {
      // Return whatever parsed successfully.
    }
    return results;
  }

  Map<String, List<String>> _parseRaw(String text) {
    final map = <String, List<String>>{};
    final regex = RegExp(r'var hq_str_(\w+)="(.*)";');
    for (final m in regex.allMatches(text)) {
      map[m.group(1)!] = m.group(2)!.split(',');
    }
    return map;
  }

  GlobalQuote? _parseQuote(GlobalQuoteDef def, List<String> f) {
    final code = def.code;
    if (code.startsWith('sh') || code.startsWith('sz')) {
      // A-share index: name, open, prevClose, price, high, low...
      if (f.length < 4) return null;
      final price = double.tryParse(f[3]);
      final prev = double.tryParse(f[2]);
      if (price == null || price <= 0 || prev == null || prev <= 0) return null;
      return _quote(def, price, price - prev, prev);
    }
    if (code.startsWith('rt_hk')) {
      // HSI: code, name, price, ?, open, low, prevClose...
      if (f.length < 7) return null;
      final price = double.tryParse(f[2]);
      final prev = double.tryParse(f[6]);
      if (price == null || price <= 0 || prev == null || prev <= 0) return null;
      return _quote(def, price, price - prev, prev);
    }
    if (code.startsWith('gb_')) {
      // US: name, price, changePct, time, change, prevClose, open
      if (f.length < 6) return null;
      final price = double.tryParse(f[1]);
      final prev = double.tryParse(f[5]);
      if (price == null || price <= 0 || prev == null || prev <= 0) return null;
      return _quote(def, price, price - prev, prev);
    }
    if (code.startsWith('int_')) {
      // Global: name, price, change, changePct
      if (f.length < 4) return null;
      final price = double.tryParse(f[1]);
      final change = double.tryParse(f[2]);
      final pct = double.tryParse(f[3]);
      if (price == null || price <= 0 || change == null) return null;
      return GlobalQuote(
        code: code,
        name: def.name,
        group: def.group,
        price: price,
        change: change,
        changePct: pct ?? 0,
        unit: def.unit,
        fxSymbol: def.fxSymbol,
      );
    }
    if (code.startsWith('hf_')) {
      // Futures: price, ?, open, ?, high, low, time, prevClose...
      if (f.length < 8) return null;
      final price = double.tryParse(f[0]);
      final prev = double.tryParse(f[7]);
      if (price == null || price <= 0) return null;
      if (prev == null || prev <= 0) {
        return GlobalQuote(
          code: code,
          name: def.name,
          group: def.group,
          price: price,
          change: 0,
          changePct: 0,
          unit: def.unit,
          fxSymbol: def.fxSymbol,
        );
      }
      return _quote(def, price, price - prev, prev);
    }
    if (code.startsWith('fx_')) {
      // FX: time, bid, ask, mid, chgPts, bid2, ask2, prevClose...
      if (f.length < 8) return null;
      final price = double.tryParse(f[3]); // mid price
      final prev = double.tryParse(f[7]);
      if (price == null || price <= 0) return null;
      if (prev == null || prev <= 0) {
        return GlobalQuote(
          code: code,
          name: def.name,
          group: def.group,
          price: price,
          change: 0,
          changePct: 0,
          unit: def.unit,
          fxSymbol: def.fxSymbol,
        );
      }
      return _quote(def, price, price - prev, prev);
    }
    return null;
  }

  GlobalQuote _quote(GlobalQuoteDef def, double price, double change, double prev) {
    return GlobalQuote(
      code: def.code,
      name: def.name,
      group: def.group,
      price: price,
      change: change,
      changePct: prev == 0 ? 0 : change / prev,
      unit: def.unit,
      fxSymbol: def.fxSymbol,
    );
  }

  // -------------------------------------------------------------------------
  // Web: Tencent (qt.gtimg.cn) serves the same catalog with full CORS
  // support. Nikkei 225 has no Tencent symbol and is skipped on the web.
  // Field layouts are identical to [TencentQuoteSource]: hf_* are
  // comma-separated (price [0], prevClose [7], changePct [1]), everything
  // else tilde-separated with price [3] / change [31] / changePct [32] for
  // stocks & indices, and price [3] / change [12] / changePct [13] for FX.
  // -------------------------------------------------------------------------

  static const _tencentCodes = {
    'sh000001': 'sh000001',
    'sz399001': 'sz399001',
    'sz399006': 'sz399006',
    'rt_hkHSI': 'hkHSI',
    // int_nikkei: no Tencent symbol; skipped on the web.
    r'gb_$dji': 'usDJI',
    'gb_inx': 'usINX',
    'gb_ixic': 'usIXIC',
    'hf_XAU': 'hf_XAU',
    'hf_GC': 'hf_GC',
    'hf_CL': 'hf_CL',
    'hf_OIL': 'hf_OIL',
    'hf_HG': 'hf_HG',
    'fx_susdcny': 'whUSDCNY',
    'fx_seurcny': 'whEURCNY',
    'fx_shkdcny': 'whHKDCNY',
    'fx_sgbpcny': 'whGBPCNY',
    'fx_sjpycny': 'whJPYCNY',
    'fx_saudcny': 'whAUDCNY',
    'fx_scadcny': 'whCADCNY',
    'fx_schfcny': 'whCHFCNY',
  };

  Future<List<GlobalQuote>> _fetchTencent() async {
    final results = <GlobalQuote>[];
    final defOf = <String, GlobalQuoteDef>{
      for (final d in GlobalQuoteCatalog.items)
        if (_tencentCodes.containsKey(d.code)) d.code: d,
    };
    try {
      final resp = await _client
          .get(Uri.parse(
              '$_baseTencent${[for (final c in defOf.keys) _tencentCodes[c]].join(',')}'))
          .timeout(marketHttpTimeout);
      if (resp.statusCode != 200) return results;
      final text = latin1.decode(resp.bodyBytes, allowInvalid: true);
      final map = _parseTencent(text);
      for (final entry in defOf.entries) {
        final q = map[_tencentCodes[entry.key]];
        if (q == null) continue;
        final parsed = _tencentQuote(entry.key, entry.value, q);
        if (parsed != null) results.add(parsed);
      }
    } catch (_) {
      // Return whatever parsed successfully.
    }
    return results;
  }

  static const _baseTencent = 'https://qt.gtimg.cn/q=';

  Map<String, List<String>> _parseTencent(String text) {
    final map = <String, List<String>>{};
    final regex = RegExp(r'v_(\w+)="([^"]*)"');
    for (final m in regex.allMatches(text)) {
      map[m.group(1)!] = m.group(2)!.split(',');
    }
    return map;
  }

  GlobalQuote? _tencentQuote(String code, GlobalQuoteDef def, List<String> f) {
    if (def.code.startsWith('hf_')) {
      // Comma-separated: price [0], prevClose [7], changePct [1].
      if (f.length < 8) return null;
      final price = double.tryParse(f[0]);
      final prev = double.tryParse(f[7]);
      if (price == null || price <= 0) return null;
      if (prev == null || prev <= 0) {
        return GlobalQuote(
          code: code,
          name: def.name,
          group: def.group,
          price: price,
          change: 0,
          changePct: 0,
          unit: def.unit,
          fxSymbol: def.fxSymbol,
        );
      }
      return _quote(def, price, price - prev, prev);
    }
    // Tilde-separated. Tencent splits on '~'; split(',') above leaves the
    // whole payload in f[0], so re-split the raw payload.
    final raw = f.length == 1 ? f[0] : f.join(',');
    final parts = raw.split('~');
    if (def.code.startsWith('fx_')) {
      if (parts.length < 14) return null;
      final price = double.tryParse(parts[3]);
      final change = double.tryParse(parts[12]);
      final pct = double.tryParse(parts[13]);
      if (price == null || price <= 0) return null;
      return GlobalQuote(
        code: code,
        name: def.name,
        group: def.group,
        price: price,
        change: change ?? 0,
        changePct: (pct ?? 0) / 100,
        unit: def.unit,
        fxSymbol: def.fxSymbol,
      );
    }
    if (parts.length < 33) return null;
    final price = double.tryParse(parts[3]);
    final change = double.tryParse(parts[31]);
    final pct = double.tryParse(parts[32]);
    if (price == null || price <= 0) return null;
    return GlobalQuote(
      code: code,
      name: def.name,
      group: def.group,
      price: price,
      change: change ?? 0,
      changePct: (pct ?? 0) / 100,
      unit: def.unit,
      fxSymbol: def.fxSymbol,
    );
  }
}
