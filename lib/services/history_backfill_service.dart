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

/// Backfills historical daily net-worth snapshots from each holding's
/// purchase date onward, so the net worth chart shows the full holding
/// period even for assets bought long before the app was first used.
///
/// Data sources:
/// - Mutual funds: Eastmoney NAV history
/// - Stocks / ETFs / LOFs: Sina daily K-line
/// - Gold accumulation: Shanghai gold futures (AU0) history
/// Manual-NAV assets (bank wealth etc.) are carried at their latest price
/// across the backfill window (they only change when the user updates them).
///
/// Recomputation is atomic: new snapshots are fully computed first, then
/// swapped in a single transaction. The UI therefore never shows a gap
/// while the rebuild is running.
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

  /// Marker for the weekend forward-fill fix + purchase-date filtering:
  /// triggers one atomic recompute of historical snapshots.
  static const _backfillV3Marker = 'backfill_v4_cost_fix';

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

    final needFullRebuild = await _dao.getSetting(_backfillV3Marker) == null;
    final existingDates = needFullRebuild
        ? <String>{}
        : (await _dao.getSnapshots()).map((s) => s.date).toSet();

    // Compute the full window day by day.
    var day = DateTime(earliest.year, earliest.month, earliest.day);
    final rows = <SnapshotRow>[];
    while (day.isBefore(todayDate)) {
      final key = todayKey(day);
      if (existingDates.contains(key)) {
        day = day.add(const Duration(days: 1));
        continue;
      }
      var assets = 0.0;
      var liabilities = 0.0;
      var cost = 0.0;
      var hasPrice = false;
      for (final h in holdings) {
        final buy = h.purchaseDate ?? h.createdAt;
        final buyDay = DateTime(buy.year, buy.month, buy.day);
        // The holding did not exist yet on this day.
        if (day.isBefore(buyDay)) continue;
        final type = AssetType.fromStorage(h.assetType);
        final filler = fillers[h.id];
        final price = filler?.priceOnOrBefore(key) ?? h.latestPrice;
        if (price > 0) hasPrice = true;
        final value = h.quantity * price;
        if (type == AssetType.liability) {
          liabilities += value;
        } else {
          assets += value;
          // Amount-based assets store the cumulative invested amount in
          // costPrice; unit-based assets store the per-unit cost.
          cost += type.isAmountBased
              ? (h.costPrice > 0 ? h.costPrice : h.quantity)
              : h.quantity * h.costPrice;
        }
      }
      if (hasPrice) {
        rows.add(SnapshotRow(
          date: key,
          currency: 'CNY',
          totalValue: assets - liabilities,
          totalCost: cost,
          createdAt: current,
        ));
      }
      day = day.add(const Duration(days: 1));
    }

    // Swap atomically so the UI never sees an empty/mid-write state.
    if (rows.isNotEmpty) {
      await _dao.transaction(() async {
        if (needFullRebuild) {
          await _dao.deleteSnapshotsBefore(todayKey(current));
        }
        await _dao.batchInsertSnapshots(rows);
      });
    }
    // Mark the rebuild done only after a successful swap.
    if (needFullRebuild) {
      await _dao.setSetting(_backfillV3Marker, '${current.millisecondsSinceEpoch}');
    }

    return BackfillResult(
      ok: true,
      days: rows.length,
      holdings: coveredHoldings,
      message: rows.isEmpty ? '历史净值已是最新' : '已回填 ${rows.length} 天历史净值',
    );
  }
}
