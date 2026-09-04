import 'market_data_source.dart';

/// A [MarketDataSource] that tries [primary] first and retries only the
/// failed symbols against [secondary].
///
/// On native platforms the primary endpoints (Sina, api.fund.eastmoney.com)
/// have the highest fidelity but can still go down or start rejecting
/// requests. Without a fallback those symbols would degrade to their cached
/// price for the whole refresh cycle; with one they are served from the
/// CORS-friendly secondary endpoints (Tencent qt.gtimg.cn, push2) instead.
///
/// The secondary is constructed with the primary's [MarketSource] label
/// (see the wiring in market_service.dart) so price-cache rows and source
/// grouping are unaffected by which endpoint actually answered.
class FallbackSource extends MarketDataSource {
  FallbackSource(this.primary, this.secondary) : super(primary.source);

  final MarketDataSource primary;
  final MarketDataSource secondary;

  @override
  Future<List<MarketQuote>> fetch(List<String> symbols) async {
    final bySymbol = <String, MarketQuote>{};
    for (final q in await primary.fetch(symbols)) {
      bySymbol[q.symbol] = q;
    }
    final failed = bySymbol.entries
        .where((e) => !e.value.isSuccess)
        .map((e) => e.key)
        .toList();
    if (failed.isEmpty) return bySymbol.values.toList();

    final secondaryBySymbol = <String, MarketQuote>{};
    for (final q in await secondary.fetch(failed)) {
      secondaryBySymbol[q.symbol] = q;
    }
    for (final symbol in failed) {
      // Some adapters normalize case (gold aliases); match
      // case-insensitively and re-emit under the requested symbol so the
      // price-cache key stays stable.
      MarketQuote? q;
      for (final e in secondaryBySymbol.entries) {
        if (e.key.toUpperCase() == symbol.toUpperCase()) {
          q = e.value;
          break;
        }
      }
      if (q == null || !q.isSuccess) continue;
      bySymbol[symbol] = MarketQuote(
        symbol: symbol,
        source: q.source,
        name: q.name,
        price: q.price,
        currency: q.currency,
        prevClose: q.prevClose,
        change: q.change,
        changePct: q.changePct,
        fetchedAt: q.fetchedAt,
      );
    }
    return bySymbol.values.toList();
  }
}
