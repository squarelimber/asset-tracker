import 'package:drift/drift.dart';

import '../core/enums.dart';
import '../core/formats.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import 'market/history_source.dart';

/// Result of a history backfill run.
class BackfillResult {
  const BackfillResult({
    required this.ok,
    required this.days,
    required this.holdings,
    this.message,
  });

  final bool ok;
  final int days;
  final int holdings;
  final String? message;
}

/// Looks up a price for any date by falling back to the most recent
/// previous trading day (forward fill). This keeps weekends/holidays on
/// the same level as the last trading day instead of jumping to the
/// current latest price.
class _ForwardFiller {
  _ForwardFiller(DailyPriceHistory history) {
    _dates = history.keys.toList()..sort();
    _prices = [for (final d in _dates) history[d]!];
  }

  late final List<String> _dates;
  late final List<double> _prices;

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

/// Backfills historical daily net-worth snapshots from the purchase date
/// onward, so the net worth chart shows the full holding period even for
/// assets bought long before the app was first used.
///
/// Data sources:
/// - Mutual funds: Eastmoney NAV history
/// - Stocks / ETFs / LOFs: Sina daily K-line
/// - Gold accumulation: Shanghai gold futures (AU0) history
/// Manual-NAV assets (bank wealth etc.) are carried at their latest price
/// across the backfill window (they only change when the user updates them).
class HistoryBackfillService {
  HistoryBackfillService(this._dao, {Map<MarketSource, HistoryDataSource>? sources})
      : _sources = sources ??
            {
              MarketSource.eastmoney: EastmoneyHistorySource(),
              MarketSource.sina: SinaKLineSource(),
              MarketSource.sge: AuGoldHistorySource(),
            };

  final AssetDao _dao;
  final Map<MarketSource, HistoryDataSource> _sources;

  /// Marker for the weekend forward-fill fix: forces one full recompute of
  /// historical snapshots that were backfilled with the wrong fallback price.
  static const _backfillV2Fixed = 'backfill_v2_forward_fill';

  /// Backfills snapshots for dates before today that are missing.
  /// Existing snapshots are never overwritten, except for the one-time
  /// recompute triggered by [_backfillV2Fixed].
  Future<BackfillResult> backfill({DateTime? now}) async {
    final current = (now ?? DateTime.now());
    final todayDate = DateTime(current.year, current.month, current.day);

    final holdings = await _dao.getHoldings();
    if (holdings.isEmpty) {
      return const BackfillResult(ok: false, days: 0, holdings: 0, message: '暂无持仓');
    }

    // Earliest purchase date across holdings defines the window start.
    DateTime? earliest;
    for (final h in holdings) {
      final d = h.purchaseDate ?? h.createdAt;
      if (earliest == null || d.isBefore(earliest)) earliest = d;
    }
    if (earliest == null) return const BackfillResult(ok: false, days: 0, holdings: 0);
    final windowStart = earliest;

    // One-time recompute: earlier backfills used the current latest price
    // for weekends, producing a jagged weekly pattern. Delete and rebuild
    // historical snapshots (today's snapshot is never touched).
    final marker = await _dao.getSetting(_backfillV2Fixed);
    if (marker == null) {
      await _dao.deleteSnapshotsBefore(todayKey(current));
      await _dao.setSetting(_backfillV2Fixed, '${current.millisecondsSinceEpoch}');
    }

    // Existing snapshot dates (we only fill missing days).
    final existing = await _dao.getSnapshots();
    final existingDates = existing.map((s) => s.date).toSet();

    // Fetch history per holding (in parallel).
    final fillers = <int, _ForwardFiller>{};
    final futures = <Future<void>>[];
    for (final h in holdings) {
      final source = MarketSource.fromStorage(h.marketSource);
      final adapter = _sources[source];
      if (adapter == null) continue;
      final symbol = h.symbol;
      if (symbol == null || symbol.isEmpty) continue;
      futures.add(() async {
        final history = await adapter.fetch(symbol, windowStart, current);
        if (history.isNotEmpty) fillers[h.id] = _ForwardFiller(history);
      }());
    }
    await Future.wait(futures);
    final coveredHoldings = fillers.length;

    // Walk day by day from the earliest date to yesterday.
    var day = DateTime(earliest.year, earliest.month, earliest.day);
    var filled = 0;
    while (day.isBefore(todayDate)) {
      final key = todayKey(day);
      if (!existingDates.contains(key)) {
        var assets = 0.0;
        var liabilities = 0.0;
        var cost = 0.0;
        var hasPrice = false;
        for (final h in holdings) {
          final type = AssetType.fromStorage(h.assetType);
          final filler = fillers[h.id];
          final price = filler?.priceOnOrBefore(key) ?? h.latestPrice;
          if (price > 0) hasPrice = true;
          final value = h.quantity * price;
          if (type == AssetType.liability) {
            liabilities += value;
          } else {
            assets += value;
            cost += h.quantity * h.costPrice;
          }
        }
        if (hasPrice) {
          await _dao.upsertSnapshot(SnapshotsCompanion.insert(
            date: key,
            currency: const Value('CNY'),
            totalValue: assets - liabilities,
            totalCost: cost,
          ));
          filled++;
        }
      }
      day = day.add(const Duration(days: 1));
    }

    return BackfillResult(
      ok: true,
      days: filled,
      holdings: coveredHoldings,
      message: filled == 0 ? '历史净值已是最新' : '已回填 $filled 天历史净值',
    );
  }
}
