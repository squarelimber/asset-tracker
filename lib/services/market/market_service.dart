import '../../core/enums.dart';
import '../../data/asset_dao.dart';
import '../../data/database.dart';
import 'coingecko_source.dart';
import 'eastmoney_source.dart';
import 'gold_fx_source.dart';
import 'market_data_source.dart';
import 'sina_source.dart';

/// Result of a full refresh cycle.
class MarketRefreshResult {
  const MarketRefreshResult({
    required this.updated,
    required this.failed,
    required this.fetchedAt,
  });

  final int updated;
  final int failed;
  final DateTime fetchedAt;

  bool get allOk => failed == 0;
}

/// Orchestrates market data fetching for all holdings:
/// groups symbols by source, fetches in parallel, writes quotes back to
/// holdings and the price cache. Failures degrade gracefully to the
/// previously cached price.
class MarketService {
  MarketService(this._dao);

  final AssetDao _dao;

  late final Map<MarketSource, MarketDataSource> _sources = {
    MarketSource.sina: SinaSource(),
    MarketSource.eastmoney: EastmoneySource(),
    // Gold (sge) holdings are served by the combined gold/fx source.
    MarketSource.sge: GoldFxSource(),
    MarketSource.forex: GoldFxSource(),
    MarketSource.coingecko: CoinGeckoSource(),
  };

  /// Refresh prices for all market-linked holdings.
  Future<MarketRefreshResult> refreshAll() async {
    final holdings = (await _dao.getHoldings())
        .where((h) => AssetType.fromStorage(h.assetType).isMarketLinked &&
            (h.symbol != null && h.symbol!.isNotEmpty))
        .toList();

    if (holdings.isEmpty) {
      return MarketRefreshResult(updated: 0, failed: 0, fetchedAt: DateTime.now());
    }

    // Group symbols by source.
    final bySource = <MarketSource, List<String>>{};
    for (final h in holdings) {
      final source = MarketSource.fromStorage(h.marketSource);
      // Gold holdings use the combined gold/fx source.
      bySource.putIfAbsent(source, () => []).add(h.symbol!);
    }

    final quoteMap = <String, MarketQuote>{};
    final futures = <Future<List<MarketQuote>>>[];
    for (final entry in bySource.entries) {
      futures.add(_fetchFromSource(entry.key, entry.value));
    }
    final batches = await Future.wait(futures);
    for (final batch in batches) {
      for (final q in batch) {
        quoteMap[q.symbol] = q;
      }
    }

    // Write quotes back.
    var updated = 0;
    var failed = 0;
    await _dao.transaction(() async {
      for (final h in holdings) {
        final quote = quoteMap[h.symbol!];
        if (quote == null || !quote.isSuccess) {
          failed++;
          continue;
        }
        await _dao.updateHoldingPrice(h.id, quote.price);
        await _dao.upsertPriceCache(PriceCacheRow(
          symbol: h.symbol!,
          source: quote.source.storageName,
          name: quote.name,
          price: quote.price,
          currency: quote.currency,
          prevClose: quote.prevClose,
          change: quote.change,
          changePct: quote.changePct,
          fetchedAt: quote.fetchedAt,
        ));
        updated++;
      }
    });

    return MarketRefreshResult(updated: updated, failed: failed, fetchedAt: DateTime.now());
  }

  Future<List<MarketQuote>> _fetchFromSource(MarketSource source, List<String> symbols) {
    final adapter = _sources[source];
    if (adapter == null) {
      return Future.value(
        symbols.map((s) => MarketQuote.failure(s, source, '无数据源')).toList(),
      );
    }
    return adapter.fetch(symbols);
  }

  /// Fetch quotes for symbols of a specific source without touching the DB.
  Future<List<MarketQuote>> fetchQuotes(MarketSource source, List<String> symbols) {
    return _fetchFromSource(source, symbols);
  }

  /// Fetches the latest price for a single holding and writes it back
  /// (holding row + price cache). Returns the fetched quote, or null.
  Future<MarketQuote?> refreshHolding(HoldingRow holding) async {
    final symbol = holding.symbol;
    if (symbol == null || symbol.isEmpty) return null;
    final source = MarketSource.fromStorage(holding.marketSource);
    final quotes = await _fetchFromSource(source, [symbol]);
    if (quotes.isEmpty) return null;
    final quote = quotes.first;
    if (!quote.isSuccess) return null;
    await _dao.transaction(() async {
      await _dao.updateHoldingPrice(holding.id, quote.price);
      await _dao.upsertPriceCache(PriceCacheRow(
        symbol: holding.symbol!,
        source: quote.source.storageName,
        name: quote.name,
        price: quote.price,
        currency: quote.currency,
        prevClose: quote.prevClose,
        change: quote.change,
        changePct: quote.changePct,
        fetchedAt: quote.fetchedAt,
      ));
    });
    return quote;
  }
}
