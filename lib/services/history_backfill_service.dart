import 'package:flutter/foundation.dart' show kIsWeb;

import '../core/enums.dart';
import '../core/formats.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import 'market/history_lookup.dart';
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

  /// Backfills snapshots for dates before today.
  ///
  /// By default only missing days are filled. With [forceRebuild], the whole
  /// window (including already-snapshot days) is recomputed and overwritten,
  /// which merges newly added / edited / removed holdings into the history.
  Future<BackfillResult> backfill({DateTime? now, bool forceRebuild = false}) async {
    // The Sina/Eastmoney history endpoints have no CORS support; the web
    // build cannot backfill history. Use the desktop/mobile app for this.
    if (kIsWeb) {
      return const BackfillResult(
        ok: false,
        days: 0,
        holdings: 0,
        message: '网页版暂不支持历史回填，请使用桌面版',
      );
    }
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
    final fillers = <int, HistoryPriceLookup>{};
    final futures = <Future<void>>[];
    for (final h in holdings) {
      final source = MarketSource.fromStorage(h.marketSource);
      final adapter = _sources[source];
      if (adapter == null) continue;
      final type = AssetType.fromStorage(h.assetType);
      var rawSymbol = (h.symbol != null && h.symbol!.isNotEmpty)
          ? h.symbol!
          : type.defaultSymbol;
      if (rawSymbol == null) continue;
      if (source == MarketSource.sina) {
        rawSymbol = normalizeSinaSymbol(rawSymbol);
      }
      final symbol = rawSymbol;
      futures.add(() async {
        try {
          final history = await adapter.fetch(symbol, windowStart, current);
          if (history.isNotEmpty) fillers[h.id] = HistoryPriceLookup(history);
        } catch (_) {
          // A single source failure must not abort the whole rebuild.
        }
      }());
    }
    await Future.wait(futures);
    final coveredHoldings = fillers.length;

    final firstTimeRebuild = await _dao.getSetting(_backfillV3Marker) == null;
    final needFullRebuild = forceRebuild || firstTimeRebuild;
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
    // Mark the one-time rebuild done only after a successful swap.
    if (firstTimeRebuild) {
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
