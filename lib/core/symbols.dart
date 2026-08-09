/// Market symbol normalization helpers.
library;

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
