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
/// (1 for CNY holdings). FX-linked holdings (银行理财 with an FX symbol)
/// store the live rate as their unit price, so the conversion is already
/// embedded in `latestPrice` and no additional factor applies — their
/// currency is a free label (e.g. USD) without double conversion.
double valueRateOf(HoldingRow h, Map<String, double> cnyRates) {
  if (h.currency == 'CNY') return 1;
  if (MarketSource.fromStorage(h.marketSource) == MarketSource.forex) {
    return 1;
  }
  return cnyRates[h.currency.toUpperCase()] ?? 1;
}

/// CNY conversion rate for a holding's cost basis: the exchange rate
/// recorded at purchase time (costFxRate), falling back to the current
/// rate. 1 for CNY holdings and FX-linked holdings (see [valueRateOf]).
double costRateOf(HoldingRow h, Map<String, double> cnyRates) {
  if (h.currency == 'CNY') return 1;
  if (MarketSource.fromStorage(h.marketSource) == MarketSource.forex) {
    return 1;
  }
  final fx = h.costFxRate;
  if (fx != null && fx > 0) return fx;
  return cnyRates[h.currency.toUpperCase()] ?? 1;
}

/// Whether the holding has no usable price HISTORY source and its history
/// should be smoothed by interpolation: manual-NAV assets (bank wealth,
/// cash-management types, manually priced bonds/futures/property) and
/// FX-linked bank wealth (a live rate exists but no historical series).
/// Liabilities are excluded — they roll up separately in the net worth.
bool isSmoothedHolding(HoldingRow h) {
  final type = AssetType.fromStorage(h.assetType);
  if (type == AssetType.liability) return false;
  final source = MarketSource.fromStorage(h.marketSource);
  if (type == AssetType.bankWealth) {
    return source == MarketSource.manual || source == MarketSource.forex;
  }
  return source == MarketSource.manual;
}
