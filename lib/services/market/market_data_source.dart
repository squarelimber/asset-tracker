import '../../core/enums.dart';

/// Default timeout for market-data HTTP requests, so a hung endpoint can
/// never wedge a refresh (or the app) forever.
const marketHttpTimeout = Duration(seconds: 15);

/// A single market quote fetched from a data source.
class MarketQuote {
  const MarketQuote({
    required this.symbol,
    required this.source,
    required this.name,
    required this.price,
    this.currency = 'CNY',
    this.prevClose,
    this.change,
    this.changePct,
    required this.fetchedAt,
  });

  final String symbol;
  final MarketSource source;
  final String name;
  final double price;
  final String currency;
  final double? prevClose;
  final double? change;
  final double? changePct;
  final DateTime fetchedAt;

  factory MarketQuote.failure(String symbol, MarketSource source, String reason) {
    return MarketQuote(
      symbol: symbol,
      source: source,
      name: reason,
      price: 0,
      fetchedAt: DateTime.now(),
    );
  }

  bool get isSuccess => price > 0;
}

/// Unified market data source interface.
/// Each adapter implements one public data endpoint.
abstract class MarketDataSource {
  MarketDataSource(this.source);

  final MarketSource source;

  /// Fetch a batch of quotes by symbol.
  /// Implementations should be resilient: return failures per-symbol
  /// instead of throwing, so one bad symbol never breaks the batch.
  Future<List<MarketQuote>> fetch(List<String> symbols);
}

/// Shared fetch helper: splits batches to avoid URL length limits.
class MarketFetchHelper {
  const MarketFetchHelper();

  static List<List<String>> chunk(List<String> items, int size) {
    final out = <List<String>>[];
    for (var i = 0; i < items.length; i += size) {
      out.add(items.sublist(i, i + size > items.length ? items.length : i + size));
    }
    return out;
  }
}
