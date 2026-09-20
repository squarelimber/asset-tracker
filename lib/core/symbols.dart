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

/// Currency codes with a live FX quote (Sina `fx_s{ccy}cny`, see
/// `GoldFxSource`). A holding whose *code* is one of these has an exchange
/// rate as its symbol — the only case where a unit price can legitimately
/// BE the rate. Single source of truth: the market source reuses this map.
const fxCurrencySymbols = <String, String>{
  'USD': 'fx_susdcny',
  'EUR': 'fx_seurcny',
  'HKD': 'fx_shkdcny',
  'GBP': 'fx_sgbpcny',
  'AUD': 'fx_saudcny',
  'CAD': 'fx_scadcny',
  'JPY': 'fx_sjpycny',
  'CHF': 'fx_schfcny',
};

/// Whether [symbol] is a supported FX currency code (e.g. `USD`), as opposed
/// to a product code (e.g. `Y05A9W10006A`, `JY040214`).
bool isFxCurrencyCode(String? symbol) =>
    symbol != null && fxCurrencySymbols.containsKey(symbol.trim().toUpperCase());

/// Whether the holding is *rate-linked*: a 银行理财 whose code is a currency
/// (e.g. `USD`) is priced by the live exchange rate, so the CNY conversion
/// is already embedded in `latestPrice` (市值 = 数量 × 汇率) and no second
/// factor may be applied — its currency is a free label.
///
/// Bank-wealth products quoted by their *product* code are NOT rate-linked
/// even though they carry `forex` as their market source (that source is
/// just the "no live NAV feed, priced manually" marker for 银行理财): the
/// unit price is a foreign-currency NAV (e.g. 1.118 USD), so both the market
/// value and the cost convert by FX like any other foreign holding.
bool isFxLinked(HoldingRow h) {
  if (MarketSource.fromStorage(h.marketSource) != MarketSource.forex) {
    return false;
  }
  return isFxCurrencyCode(h.symbol);
}

/// Currency codes in [currencies] that [cnyRates] cannot convert to CNY.
///
/// [valueRateOf] returns 1 for a code it does not know, which keeps the UI
/// working for a genuinely rate-less holding but makes a **partial** rate
/// table dangerous: the whole FX leg silently disappears and the result
/// still looks like a plausible number. Callers that persist the figure
/// (daily snapshots, history rebuilds) must refuse to write while this list
/// is non-empty, rather than record a value they know is wrong.
List<String> missingCnyRates(
  Iterable<String> currencies,
  Map<String, double> cnyRates,
) {
  final missing = <String>[];
  for (final raw in currencies) {
    final code = raw.toUpperCase();
    if (code == 'CNY') continue;
    if (!((cnyRates[code] ?? 0) > 0)) missing.add(code);
  }
  return missing;
}

/// CNY conversion rate for a holding's market value: the current FX rate
/// (1 for CNY holdings and rate-linked holdings, see [isFxLinked]).
double valueRateOf(HoldingRow h, Map<String, double> cnyRates) {
  if (h.currency == 'CNY') return 1;
  if (isFxLinked(h)) return 1;
  return cnyRates[h.currency.toUpperCase()] ?? 1;
}

/// CNY conversion rate for a holding's cost basis: the exchange rate
/// recorded at purchase time (costFxRate), falling back to the current
/// rate. 1 for CNY holdings and rate-linked holdings (see [isFxLinked]).
double costRateOf(HoldingRow h, Map<String, double> cnyRates) {
  if (h.currency == 'CNY') return 1;
  if (isFxLinked(h)) return 1;
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
