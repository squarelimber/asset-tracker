import 'history_source.dart';

/// Looks up a price for any date by falling back to the most recent
/// previous trading day (forward fill). This keeps weekends/holidays on
/// the same level as the last trading day instead of jumping to the
/// current latest price.
class HistoryPriceLookup {
  HistoryPriceLookup(DailyPriceHistory history) {
    _dates = history.keys.toList()..sort();
    _prices = [for (final d in _dates) history[d]!];
  }

  late final List<String> _dates;
  late final List<double> _prices;

  /// The latest date in the history (yyyy-MM-dd), or null when empty.
  String? get lastDate => _dates.isEmpty ? null : _dates.last;

  /// Price on [key] (yyyy-MM-dd) or the most recent date <= [key], else null.
  double? priceOnOrBefore(String key) {
    var lo = 0;
    var hi = _dates.length - 1;
    var ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (_dates[mid].compareTo(key) <= 0) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans < 0 ? null : _prices[ans];
  }
}
