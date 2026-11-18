import '../core/enums.dart';
import '../data/database.dart';
import 'bse_code_mapping.dart';

/// Returns the Tencent symbol for a supported holding. Currency and an
/// explicit exchange prefix resolve collisions between markets.
String? klineSymbolForHolding(HoldingRow holding) {
  final type = AssetType.fromStorage(holding.assetType);
  final raw = holding.symbol?.trim();
  if (raw == null || raw.isEmpty) return null;
  final currency = holding.currency.trim().toUpperCase();

  // Older holdings can carry an exposure type (gold, commodity, bond, etc.)
  // or an Eastmoney source even though their product is exchange traded.
  // Normally require an explicit exchange prefix: bare fund codes can also
  // refer to off-exchange holdings. Stock holdings with a stock quote source
  // are already exchange-traded and may safely use a bare code.
  final legacyFundType = switch (type) {
    AssetType.stock ||
    AssetType.mutualFund ||
    AssetType.gold ||
    AssetType.bond ||
    AssetType.crypto ||
    AssetType.futures => true,
    _ => false,
  };
  if (currency == 'CNY' && legacyFundType) {
    var symbol = raw.toLowerCase();
    if (type == AssetType.stock &&
        (holding.marketSource == MarketSource.sina.storageName ||
            holding.marketSource == MarketSource.manual.storageName) &&
        RegExp(r'^[15]\d{5}$').hasMatch(symbol)) {
      symbol = '${symbol.startsWith('5') ? 'sh' : 'sz'}$symbol';
    }
    if (RegExp(
      r'^(?:sh5(?!19)\d{5}|sz(?:159\d{3}|1[68]\d{4}))$',
    ).hasMatch(symbol)) {
      return symbol;
    }
  }

  if (type != AssetType.stock && type != AssetType.etf) return null;
  if (type == AssetType.stock &&
      holding.marketSource != MarketSource.sina.storageName &&
      holding.marketSource != MarketSource.manual.storageName) {
    return null;
  }

  if (currency == 'CNY') {
    var symbol = raw.toLowerCase();
    if (type == AssetType.stock) {
      final oldCode = symbol.startsWith('bj') ? symbol.substring(2) : symbol;
      final currentCode = bseLegacyCodeMapping[oldCode];
      if (currentCode != null) return 'bj$currentCode';
    }
    if (RegExp(r'^\d{6}$').hasMatch(symbol)) {
      final exchange = switch (symbol[0]) {
        '5' || '6' => 'sh',
        '0' || '1' || '3' => 'sz',
        '9' => 'bj',
        _ => '',
      };
      symbol = '$exchange$symbol';
    }
    final pattern = type == AssetType.stock
        ? RegExp(r'^(?:sh6\d{5}|sz[03]\d{5}|bj92\d{4})$')
        : RegExp(r'^(?:sh5\d{5}|sz1\d{5})$');
    return pattern.hasMatch(symbol) ? symbol : null;
  }

  if (currency == 'HKD') {
    final symbol = raw.toLowerCase().replaceFirst(RegExp(r'^(?:rt_)?hk'), '');
    if (!RegExp(r'^\d{1,5}$').hasMatch(symbol)) return null;
    return 'hk${symbol.padLeft(5, '0')}';
  }

  if (currency == 'USD') {
    if (RegExp(r'^(?:rt_)?hk\d{1,5}$', caseSensitive: false).hasMatch(raw)) {
      return null;
    }
    // Sina's gb_ prefix is explicit. Tencent's us prefix is lowercase;
    // uppercase USO, for example, is itself a valid ticker.
    var symbol = raw;
    if (symbol.toLowerCase().startsWith('gb_')) {
      symbol = symbol.substring(3);
    } else if (symbol.startsWith('us') && symbol.length > 2) {
      symbol = symbol.substring(2);
    }
    symbol = symbol.toUpperCase();
    if (!RegExp(
      r'^[A-Z][A-Z0-9]{0,9}(?:\.[A-Z]{1,2}){0,2}$',
    ).hasMatch(symbol)) {
      return null;
    }
    return 'us$symbol';
  }
  return null;
}
