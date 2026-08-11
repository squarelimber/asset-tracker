/// Market symbol normalization helpers.
library;

import '../data/database.dart';
import 'enums.dart';

final _pureSixDigit = RegExp(r'^\d{6}$');

/// Normalizes a bare 6-digit A-share/ETF code to the Sina format:
/// - 5xxxxx / 6xxxxx -> shxxxxxx (Shanghai)
/// - 0xxxxx / 1xxxxx / 3xxxxx -> szxxxxxx (Shenzhen)
/// Codes that already carry a prefix (sh/sz/hk...) pass through unchanged.
String normalizeSinaSymbol(String symbol) {
  final s = symbol.trim();
  if (!_pureSixDigit.hasMatch(s)) return s;
  return switch (s[0]) {
    '5' || '6' => 'sh$s',
    _ => 'sz$s',
  };
}

/// The symbol key under which this holding's quote is cached in
/// `price_cache`, matching the normalization used by `MarketService`
/// (bare 6-digit Sina codes get an exchange prefix, gold defaults to
/// AU99.99). Manual/amount-based holdings return null (no quote).
String? cacheSymbolFor(HoldingRow holding) {
  final type = AssetType.fromStorage(holding.assetType);
  if (type.isAmountBased) return null;
  final raw = (holding.symbol != null && holding.symbol!.isNotEmpty)
      ? holding.symbol!
      : type.defaultSymbol;
  if (raw == null) return null;
  final source = MarketSource.fromStorage(holding.marketSource);
  return source == MarketSource.sina ? normalizeSinaSymbol(raw) : raw;
}
