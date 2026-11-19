import 'package:drift/drift.dart' show Value;

import '../core/enums.dart';
import '../core/formats.dart';
import '../core/symbols.dart';
import '../data/database.dart';
import 'holding_valuation.dart';
import 'product_monthly_earnings.dart';
import 'transaction_identity.dart';

/// Cumulative realized gain, separate from holdings and cash still tracked.
/// Use a fresh cursor for each pass over an ascending snapshot series.
class ExternalSaleGains {
  ExternalSaleGains(
    List<HoldingRow> holdings,
    List<TransactionRow> transactions,
    Map<String, double> rates, {
    Map<int, double> replayedPrincipal = const {},
  }) {
    final byId = {for (final h in holdings) h.id: h};
    final sales = transactions.where(isExternalSale).toList();
    final missing = {
      for (final sale in sales)
        if (sale.externalSellPrincipal == null &&
            !replayedPrincipal.containsKey(sale.id))
          sale.holdingId!,
    };
    final recovered = <int, double>{...replayedPrincipal};
    if (missing.isNotEmpty) {
      final relevant = <int, List<TransactionRow>>{};
      for (final transaction in transactions) {
        final id = transaction.holdingId;
        if (id != null && missing.contains(id)) {
          (relevant[id] ??= []).add(transaction);
        }
      }
      for (final id in missing) {
        final holding = byId[id];
        if (holding == null ||
            AssetType.fromStorage(holding.assetType).isAmountBased) {
          continue;
        }
        final events = relevant[id]!
          ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
        // Principal is captured even for flows earlier than the start of the
        // requested window. A single end day suffices to replay them all.
        final end = events.last.occurredAt.toLocal();
        const HoldingReplay().replay(
          holding,
          events,
          from: end,
          to: end,
          capturedSellPrincipal: recovered,
        );
      }
    }
    for (final sale in sales) {
      final holding = byId[sale.holdingId];
      if (holding == null ||
          AssetType.fromStorage(holding.assetType).isAmountBased) {
        continue;
      }
      final principal = sale.externalSellPrincipal ?? recovered[sale.id];
      final proceedsRate = isFxLinked(holding)
          ? 1.0
          : cnyRateOf(sale.currency, rates);
      final basisRate = costRateOfOrNull(holding, rates);
      if (principal == null || proceedsRate == null || basisRate == null) {
        continue;
      }
      final gain = sale.amount * proceedsRate - principal * basisRate;
      if (gain.isFinite && gain != 0) {
        _events.add((
          date: todayKey(sale.occurredAt.toLocal()),
          id: holding.id,
          gain: gain,
        ));
      }
    }
    _events.sort((a, b) => a.date.compareTo(b.date));
  }

  final _events = <({String date, int id, double gain})>[];
  final _gains = <int, double>{};
  var _index = 0;
  double total = 0;

  void advanceTo(String date) {
    while (_index < _events.length &&
        _events[_index].date.compareTo(date) <= 0) {
      final entry = _events[_index++];
      _gains.update(
        entry.id,
        (amount) => amount + entry.gain,
        ifAbsent: () => entry.gain,
      );
      total += entry.gain;
    }
  }

  double forHolding(int id) => _gains[id] ?? 0;

  /// Keep old synced snapshots usable on clients without historical quotes.
  /// Their original valuation and timestamps stay intact.
  List<SnapshotRow> fillLegacy(List<SnapshotRow> snapshots) => [
    for (final snapshot in snapshots) _fillSnapshot(snapshot),
  ];

  SnapshotRow _fillSnapshot(SnapshotRow snapshot) {
    advanceTo(snapshot.date);
    if (snapshot.realizedProfit != null || _gains.isEmpty) {
      return snapshot;
    }
    final values = snapshotHoldingValues(snapshot);
    return snapshot.copyWith(
      realizedProfit: Value(total),
      holdingValues: Value(
        values == null
            ? snapshot.holdingValues
            : encodeHoldingValues([
                for (final value in values)
                  value.withRealizedProfit(forHolding(value.holdingId)),
              ]),
      ),
    );
  }
}
