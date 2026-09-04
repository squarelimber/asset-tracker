import 'package:flutter/foundation.dart' show kIsWeb;

import '../../core/enums.dart';
import '../../core/symbols.dart';
import '../../data/asset_dao.dart';
import '../../data/database.dart';
import 'coingecko_source.dart';
import 'eastmoney_fund_quote_source.dart';
import 'eastmoney_source.dart';
import 'fallback_source.dart';
import 'gold_fx_source.dart';
import 'market_data_source.dart';
import 'sina_source.dart';
import 'tencent_quote_source.dart';

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

  // The Sina/Eastmoney endpoints used on native platforms have no CORS
  // headers and require a Referer header, so the web build uses the
  // CORS-friendly Tencent / Eastmoney push2 endpoints instead.
  late final Map<MarketSource, MarketDataSource> _sources = kIsWeb
      ? {
          MarketSource.sina: TencentQuoteSource(source: MarketSource.sina),
          MarketSource.eastmoney: EastmoneyFundQuoteSource(),
          // Gold (sge) holdings are served by the combined gold/fx adapter.
          MarketSource.sge: TencentGoldFxAdapter(),
          MarketSource.forex: TencentGoldFxAdapter(),
          MarketSource.coingecko: CoinGeckoSource(),
        }
      : {
          // Native: highest-fidelity endpoints first, with the CORS-friendly
          // web endpoints as fallback so a single endpoint outage degrades
          // to a slower source instead of stale cached prices.
          MarketSource.sina: FallbackSource(
            SinaSource(),
            TencentQuoteSource(source: MarketSource.sina),
          ),
          MarketSource.eastmoney: FallbackSource(
            EastmoneySource(),
            EastmoneyFundQuoteSource(),
          ),
          // Gold (sge) holdings are served by the combined gold/fx source.
          MarketSource.sge: FallbackSource(GoldFxSource(), TencentGoldFxAdapter()),
          MarketSource.forex: FallbackSource(GoldFxSource(), TencentGoldFxAdapter()),
          MarketSource.coingecko: CoinGeckoSource(),
        };

  /// Refresh prices for all market-linked holdings.
  Future<MarketRefreshResult> refreshAll() async {
    final holdings = (await _dao.getHoldings())
        .where((h) => AssetType.fromStorage(h.assetType).isMarketLinked)
        .toList();

    if (holdings.isEmpty) {
      return MarketRefreshResult(updated: 0, failed: 0, fetchedAt: DateTime.now());
    }

    // Group symbols by source. Holdings without a code use the type's
    // default symbol (e.g. gold -> AU99.99) so they stay auto-synced.
    final bySource = <MarketSource, List<String>>{};
    final symbolOf = <int, String>{};
    for (final h in holdings) {
      final type = AssetType.fromStorage(h.assetType);
      var symbol = (h.symbol != null && h.symbol!.isNotEmpty)
          ? h.symbol!
          : type.defaultSymbol;
      if (symbol == null) continue;
      final source = MarketSource.fromStorage(h.marketSource);
      // Bare 6-digit A-share/ETF codes need the exchange prefix for Sina.
      if (source == MarketSource.sina) {
        symbol = normalizeSinaSymbol(symbol);
      }
      bySource.putIfAbsent(source, () => []).add(symbol);
      symbolOf[h.id] = symbol;
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
        final symbol = symbolOf[h.id];
        if (symbol == null) continue;
        final quote = quoteMap[symbol];
        if (quote == null || !quote.isSuccess) {
          failed++;
          continue;
        }
        await _dao.updateHoldingPrice(h.id, quote.price);
        await _dao.upsertPriceCache(PriceCacheRow(
          symbol: symbol,
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

    // Refresh FX rates for any non-CNY currency in use (rates cached in
    // price_cache with a 24h TTL, see loadCnyRates).
    final currencies = holdings
        .map((h) => h.currency)
        .where((c) => c != 'CNY')
        .toSet()
        .toList();
    await loadCnyRates(currencies);

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

  /// How long a cached FX rate is trusted before a live re-fetch.
  static const _fxTtl = Duration(hours: 24);

  /// CNY per unit for the given currency codes, combining the cached rates
  /// with a live fetch for missing or stale ones. A stale cache value is
  /// used as a last resort when the live fetch fails, so conversions keep
  /// working offline; unknown codes are omitted.
  Future<Map<String, double>> loadCnyRates(List<String> currencies) async {
    final unique = currencies.map((c) => c.toUpperCase()).toSet().toList();
    if (unique.isEmpty) return const {};
    final rates = <String, double>{};
    final stale = <String, double>{};

    final cached = await _dao.getCachedPrices(unique);
    final now = DateTime.now();
    for (final c in unique) {
      final row = cached[c];
      if (row == null || row.price <= 0) continue;
      if (now.difference(row.fetchedAt) <= _fxTtl) {
        rates[c] = row.price;
      } else {
        stale[c] = row.price;
      }
    }

    final missing = unique.where((c) => !rates.containsKey(c)).toList();
    if (missing.isNotEmpty) {
      try {
        final quotes = await fetchQuotes(MarketSource.forex, missing);
        for (final q in quotes) {
          if (q.isSuccess && q.price > 0) {
            rates[q.symbol] = q.price;
            await _dao.upsertPriceCache(PriceCacheRow(
              symbol: q.symbol,
              source: q.source.storageName,
              name: q.name,
              price: q.price,
              currency: q.currency,
              prevClose: q.prevClose,
              change: q.change,
              changePct: q.changePct,
              fetchedAt: q.fetchedAt,
            ));
          }
        }
      } catch (_) {
        // Offline: fall back to the stale cache values below.
      }
    }
    for (final c in unique) {
      if (!rates.containsKey(c) && stale.containsKey(c)) rates[c] = stale[c]!;
    }
    return rates;
  }

  /// Fetches the latest price for a single holding and writes it back
  /// (holding row + price cache). Returns the fetched quote, or null.
  Future<MarketQuote?> refreshHolding(HoldingRow holding) async {
    final type = AssetType.fromStorage(holding.assetType);
    var rawSymbol = (holding.symbol != null && holding.symbol!.isNotEmpty)
        ? holding.symbol!
        : type.defaultSymbol;
    if (rawSymbol == null) return null;
    final source = MarketSource.fromStorage(holding.marketSource);
    if (source == MarketSource.sina) {
      rawSymbol = normalizeSinaSymbol(rawSymbol);
    }
    final symbol = rawSymbol;
    final quotes = await _fetchFromSource(source, [symbol]);
    if (quotes.isEmpty) return null;
    final quote = quotes.first;
    if (!quote.isSuccess) return null;
    await _dao.transaction(() async {
      await _dao.updateHoldingPrice(holding.id, quote.price);
      await _dao.upsertPriceCache(PriceCacheRow(
        symbol: symbol,
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
