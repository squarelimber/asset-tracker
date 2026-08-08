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

  /// Backfills snapshots for dates before today that are missing.
  /// Existing snapshots are never overwritten.
  Future<BackfillResult> backfill({DateTime? now}) async {
    final current = (now ?? DateTime.now());

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

    // Existing snapshot dates (we only fill missing days).
    final existing = await _dao.getSnapshots();
    final existingDates = existing.map((s) => s.date).toSet();

    // Fetch history per holding (in parallel).
    final historyByHolding = <int, DailyPriceHistory>{};
    final futures = <Future<void>>[];
    for (final h in holdings) {
      final source = MarketSource.fromStorage(h.marketSource);
      final adapter = _sources[source];
      if (adapter == null) continue;
      final symbol = h.symbol;
      if (symbol == null || symbol.isEmpty) continue;
      futures.add(() async {
        final history = await adapter.fetch(symbol, windowStart, current);
        if (history.isNotEmpty) historyByHolding[h.id] = history;
      }());
    }
    await Future.wait(futures);
    final coveredHoldings = historyByHolding.length;

    // Walk day by day from the earliest date to yesterday.
    var day = DateTime(earliest.year, earliest.month, earliest.day);
    final todayDate = DateTime(current.year, current.month, current.day);
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
          final hist = historyByHolding[h.id];
          final price = hist?[key];
          final p = price ?? h.latestPrice;
          if (p > 0) hasPrice = true;
          final value = h.quantity * p;
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
