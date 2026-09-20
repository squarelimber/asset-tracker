import 'package:drift/drift.dart';

import '../core/formats.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/portfolio_calculator.dart';
import 'market/market_service.dart';

/// Records one net-worth snapshot per day (per currency).
/// Called on app start / after refresh; idempotent for the same day.
/// Values are converted to CNY using current FX rates.
///
/// This is the *fallback* writer for today: whenever a history rebuild can
/// run it also covers today, and re-derives it from the same price series
/// as every earlier day. This class exists so that platforms that cannot
/// backfill (web) and runs whose history fetch failed still get a row for
/// today instead of an empty calendar cell.
class SnapshotService {
  SnapshotService(
    this._dao, {
    DateTime Function()? clock,
    this._market,
  }) : _clock = clock ?? DateTime.now;

  final AssetDao _dao;
  final DateTime Function() _clock;
  final MarketService? _market;

  /// Ensures today's snapshot exists; recomputes it if the cached quote
  /// prices are newer than the snapshot's creation time.
  ///
  /// [force] rewrites an existing row. Callers must only pass it once the
  /// quotes behind the numbers are known to be fresh — see the refresh gate
  /// on the portfolio page — because a rewrite from stale prices replaces a
  /// correct figure with a wrong one.
  Future<void> ensureTodaySnapshot({bool force = false}) async {
    final now = _clock();
    final dateKey = todayKey(now);
    final existing = await _dao.getSnapshot(dateKey, 'CNY');
    if (existing != null && !force) return;

    final holdings = await _dao.getHoldings();
    // A fresh install (or a device that hasn't received its first sync yet)
    // has no holdings. Recording a zero-valued snapshot here would corrupt
    // the net-worth trend and — because snapshots sync with last-write-wins —
    // push that corruption to every other device. Skip until there is data.
    if (holdings.isEmpty) return;
    // Convert non-CNY holdings with current FX rates so today's snapshot
    // matches the dashboard figures. Rate-linked 银行理财 (symbol = a
    // currency code) already embed the conversion in `latestPrice`, so they
    // need no rate and must not be reported as missing one.
    final currencies = holdings
        .where((h) => h.currency != 'CNY' && !isFxLinked(h))
        .map((h) => h.currency)
        .toSet()
        .toList();
    final rates = _market == null
        ? const <String, double>{}
        : await _market.loadCnyRates(currencies);
    // A rate we could not obtain makes `valueRateOf` silently fall back to 1,
    // dropping the entire FX leg from net worth so the total still looks
    // plausible. Snapshots merge across devices with last-write-wins, so a
    // wrong figure written here does not stay here — it is pushed to every
    // other device and re-read as the basis for that day's earnings. Skip
    // the day instead: an empty cell is recoverable, a synchronised wrong
    // total is not. A later refresh with real rates fills it in.
    if (missingCnyRates(currencies, rates).isNotEmpty) return;
    final summary =
        const PortfolioCalculator().compute(holdings, cnyRates: rates);

    await _dao.upsertSnapshot(SnapshotsCompanion.insert(
      date: dateKey,
      currency: const Value('CNY'),
      totalValue: summary.netWorth,
      totalCost: summary.totalCost,
      liabilities: Value(summary.totalLiabilities),
      // Written explicitly, even though the column has a DB default: the
      // column doubles as the cross-device last-write-wins version (see
      // SyncFormatter.snapshotToRow) and `insertOnConflictUpdate` only
      // updates the columns a companion actually carries. Leaving it
      // implicit froze the version at the day's first write, so a corrected
      // rewrite could never win the merge on another device.
      createdAt: Value(now),
    ));
  }
}
