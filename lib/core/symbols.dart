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

/// CNY conversion rate for a holding's market value: the current FX rate
/// (1 for CNY holdings).
double valueRateOf(HoldingRow h, Map<String, double> cnyRates) {
  if (h.currency == 'CNY') return 1;
  return cnyRates[h.currency.toUpperCase()] ?? 1;
}

/// CNY conversion rate for a holding's cost basis: the exchange rate
/// recorded at purchase time (costFxRate), falling back to the current
/// rate. 1 for CNY holdings.
double costRateOf(HoldingRow h, Map<String, double> cnyRates) {
  if (h.currency == 'CNY') return 1;
  final fx = h.costFxRate;
  if (fx != null && fx > 0) return fx;
  return cnyRates[h.currency.toUpperCase()] ?? 1;
}

/// Whether the holding has no market source and its history should be
/// smoothed by interpolation (bank wealth + cash-management types).
/// Property and liabilities are excluded.
bool isSmoothedHolding(HoldingRow h) {
  final type = AssetType.fromStorage(h.assetType);
  if (MarketSource.fromStorage(h.marketSource) != MarketSource.manual) {
    return false;
  }
  if (type == AssetType.bankWealth) return true;
  return type.isAmountBased;
}
