import 'package:flutter/foundation.dart' show listEquals;

import '../core/formats.dart';
import '../core/enums.dart';
import '../core/symbols.dart';
import '../data/asset_dao.dart';
import '../data/database.dart';
import '../domain/cash_flow_adjustments.dart';
import '../domain/external_sale_gains.dart';
import '../domain/portfolio_calculator.dart';
import '../domain/holding_cost.dart';
import '../domain/holding_valuation.dart';
import '../domain/legacy_transfer_principal.dart';
import '../domain/product_monthly_earnings.dart' show HoldingReplay;
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
  SnapshotService(this._dao, {DateTime Function()? clock, this._market})
    : _clock = clock ?? DateTime.now;

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

    final (holdings, transactions, history) = await _dao.transaction(
      () async => (
        await _dao.getHoldings(),
        await _dao.getTransactions(),
        await _dao.getSnapshots(),
      ),
    );
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
    final summary = const PortfolioCalculator().compute(
      holdings,
      cnyRates: rates,
    );

    final historyTransactions = resolveLegacyTransferPrincipal(
      history,
      transactions,
    );
    // Rebuilding history and refreshing today must use the same cost basis.
    // A manually entered/rounded holding unit cost can differ from the
    // recorded principal of its buys. Switching back to it on refresh would
    // create a cost movement without a transaction and break the risk series.
    // This is calculation-only: preserve the user's original holding fields.
    final day = DateTime(now.year, now.month, now.day);
    final flowsByHolding = <int, List<TransactionRow>>{};
    for (final row in historyTransactions) {
      final id = row.holdingId;
      if (id != null) (flowsByHolding[id] ??= []).add(row);
    }
    final shareCosts = <int, double>{
      for (final h in holdings)
        if (!AssetType.fromStorage(h.assetType).isAmountBased &&
            h.assetType != 'liability')
          h.id: const HoldingReplay()
              .replay(
                h,
                flowsByHolding[h.id] ?? const [],
                from: day,
                to: day,
              )[dateKey]!
              .$2,
    };
    final realized = ExternalSaleGains(holdings, historyTransactions, rates)
      ..advanceTo(dateKey);
    final values = [
      for (final h in holdings)
        DayHoldingValue(
          holdingId: h.id,
          name: h.name,
          type: AssetType.fromStorage(h.assetType),
          value:
              (AssetType.fromStorage(h.assetType).isAmountBased
                  ? h.quantity
                  : h.quantity * h.latestPrice) *
              valueRateOf(h, rates),
          cost: h.assetType == 'liability'
              ? 0
              : (AssetType.fromStorage(h.assetType).isAmountBased
                        ? effectiveCostOf(h)
                        : shareCosts[h.id]!) *
                    costRateOf(h, rates),
          liability: h.assetType == 'liability',
          realizedProfit: realized.forHolding(h.id),
        ),
    ];
    final snapshot = SnapshotRow(
      date: dateKey,
      currency: 'CNY',
      totalValue: summary.netWorth,
      totalCost: values.fold(0.0, (sum, value) => sum + value.cost),
      liabilities: summary.totalLiabilities,
      realizedProfit: realized.total,
      holdingValues: encodeHoldingValues(values),
      // Written explicitly, even though the column has a DB default: the
      // column doubles as the cross-device last-write-wins version (see
      // SyncFormatter.snapshotToRow) and `insertOnConflictUpdate` only
      // updates the columns a companion actually carries. Leaving it
      // implicit froze the version at the day's first write, so a corrected
      // rewrite could never win the merge on another device.
      createdAt: now,
    );
    // A forced rewrite of today must replay from an earlier date, never from
    // today's already-adjusted row (which would apply each payout twice).
    final earlier =
        history
            .where(
              (row) => row.currency == 'CNY' && row.date.compareTo(dateKey) < 0,
            )
            .toList()
          ..sort((a, b) => a.date.compareTo(b.date));
    final prior = earlier.lastOrNull;
    final adjustment = cashFlowAdjustmentsBetween(
      prior,
      snapshot,
      transactions: historyTransactions,
    );
    if (!adjustment.verified) return;
    final corrected = adjustment.applyTo(snapshot);
    await _dao.transaction(() async {
      if (listEquals(holdings, await _dao.getHoldings()) &&
          listEquals(transactions, await _dao.getTransactions()) &&
          listEquals(history, await _dao.getSnapshots()) &&
          existing == await _dao.getSnapshot(dateKey, 'CNY')) {
        await _dao.upsertSnapshot(corrected.toCompanion(true));
      }
    });
  }
}
