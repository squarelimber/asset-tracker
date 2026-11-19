import '../core/enums.dart';
import '../core/formats.dart';
import '../core/market_session.dart';
import '../core/symbols.dart';
import '../data/database.dart';
import 'transaction_identity.dart';
import '../services/market/kline_source.dart';
import 'holding_kline.dart';

typedef PortfolioSample = ({int minute, double profit});
typedef PortfolioIntradayHistory = ({
  List<PortfolioSample> points,
  int covered,
  int eligible,
});

/// Treat the clock fields as China market time regardless of device zone.
DateTime chinaMarketTime(DateTime instant) =>
    instant.toUtc().add(const Duration(hours: 8));

bool prefersTodayTrend(DateTime instant) {
  final session = aShareSession(chinaMarketTime(instant));
  return session == MarketSession.open || session == MarketSession.lunch;
}

/// Share-based holdings needing a price, including ones fully sold today.
/// Cash and liabilities have no exchange price, and their transfers net out.
List<HoldingRow> intradayPriceHoldings(
  List<HoldingRow> holdings,
  List<TransactionRow> transactions,
) {
  final traded = {
    for (final row in transactions)
      if (row.type == TransactionType.sell.storageName) row.holdingId,
  };
  return holdings.where((holding) {
    final type = AssetType.fromStorage(holding.assetType);
    return !type.isAmountBased &&
        type != AssetType.liability &&
        (holding.quantity > 0 || traded.contains(holding.id));
  }).toList();
}

/// Mark each security to its minute price with the shares held at that time.
/// In both funded and unfunded trades the cash counterpart is the recorded
/// amount. Including it here preserves the fill gain/loss and ignores the
/// movement of principal. Other prices and FX are held constant.
PortfolioIntradayHistory rebuildPortfolioIntraday({
  required String day,
  required DateTime now,
  required List<HoldingRow> priceHoldings,
  required List<TransactionRow> transactions,
  required Map<String, MarketIntraday> quotes,
  required Map<String, double> rates,
}) {
  final start = DateTime.parse('${day}T00:00:00+08:00');
  final profits = <Map<int, double>>[];
  for (final holding in priceHoldings) {
    final quote = quotes[klineSymbolForHolding(holding)];
    final previousClose = quote?.previousClose;
    final currency = holding.currency.toUpperCase();
    final rate = currency == 'CNY' ? 1.0 : rates[currency];
    if (quote == null ||
        quote.date != day ||
        previousClose == null ||
        rate == null ||
        !rate.isFinite ||
        rate <= 0) {
      continue;
    }

    final trades =
        [
          for (final row in transactions)
            if (row.holdingId == holding.id) row,
        ]..sort((a, b) {
          final order = a.occurredAt.compareTo(b.occurredAt);
          return order == 0 ? compareTransactionEntryOrder(a, b) : order;
        });
    final moves = <({DateTime time, double shares, double cash})>[];
    var openingShares = holding.quantity;
    var replayable = true;
    for (final row in trades) {
      final type = TransactionType.fromStorage(row.type);
      if (type == TransactionType.split) {
        // The minute feed supplies today's trading units only.
        replayable = false;
        break;
      }
      if (type == TransactionType.dividend && row.cashTargetId != null) {
        moves.add((time: row.occurredAt, shares: 0, cash: row.amount));
      }
      if (type != TransactionType.buy && type != TransactionType.sell) continue;
      final qty = row.quantity;
      if (qty == null || !qty.isFinite || qty <= 0 || !row.amount.isFinite) {
        replayable = false;
        break;
      }
      final sign = type == TransactionType.buy ? 1 : -1;
      final shares = sign * qty;
      openingShares -= shares;
      moves.add((
        time: row.occurredAt,
        shares: shares,
        cash: -sign * row.amount,
      ));
    }
    if (!replayable || !openingShares.isFinite || openingShares < -1e-6) {
      continue;
    }

    final previousValue = openingShares * previousClose;
    final series = <int, double>{};
    var shares = openingShares;
    var cash = 0.0;
    var next = 0;
    for (final point in quote.points) {
      final minute = point.minute;
      final time = start.add(Duration(minutes: minute));
      if (minute < 570 ||
          minute > 900 ||
          time.isAfter(now) ||
          (minute > 690 && minute < 780)) {
        continue;
      }
      // A label such as 10:01 represents that minute's market observation.
      // Apply trades in it, but never apply a trade timestamped in the future.
      final end = time.add(const Duration(minutes: 1));
      while (next < moves.length &&
          moves[next].time.isBefore(end) &&
          !moves[next].time.isAfter(now)) {
        shares += moves[next].shares;
        cash += moves[next].cash;
        next++;
      }
      if (shares < -1e-6) {
        replayable = false;
        break;
      }
      final profit = (shares * point.value - previousValue + cash) * rate;
      if (profit.isFinite) series[minute] = profit;
    }
    if (replayable && series.isNotEmpty) profits.add(series);
  }

  final points = <PortfolioSample>[];
  if (profits.isNotEmpty) {
    // A timestamp is usable only when every included holding has a mark.
    // Dropping an individual holding for a minute would create a false jump.
    for (final minute in profits.first.keys) {
      if (profits.every((series) => series.containsKey(minute))) {
        points.add((
          minute: minute,
          profit: profits.fold(0.0, (sum, series) => sum + series[minute]!),
        ));
      }
    }
  }
  return (
    points: points,
    covered: profits.length,
    eligible: priceHoldings.length,
  );
}

/// Change in net worth minus external flows recorded in this interval.
/// Both sides of a transfer (including repayment/borrowing) are in net worth.
double? intradayPortfolioProfit({
  required SnapshotRow baseline,
  required List<HoldingRow> holdings,
  required List<TransactionRow> transactions,
  required Map<String, double> rates,
  required DateTime now,
}) {
  if (holdings.isEmpty) return null;
  double? rateOf(String currency) =>
      currency.toUpperCase() == 'CNY' ? 1 : rates[currency.toUpperCase()];
  var value = 0.0;
  for (final h in holdings) {
    if (h.quantity == 0) continue;
    final type = AssetType.fromStorage(h.assetType);
    final rate = isFxLinked(h) ? 1.0 : rateOf(h.currency);
    if (rate == null || !rate.isFinite || rate <= 0) return null;
    if (type == AssetType.liability) {
      value -= h.quantity * rate;
    } else {
      value += h.quantity * (type.isAmountBased ? 1 : h.latestPrice) * rate;
    }
  }

  var external = 0.0;
  for (final t in transactions) {
    // Snapshots and transaction records use the app's local ledger dates.
    if (todayKey(t.occurredAt.toLocal()).compareTo(baseline.date) <= 0 ||
        t.occurredAt.isAfter(now)) {
      continue;
    }
    final type = TransactionType.values
        .where((type) => type.storageName == t.type)
        .firstOrNull;
    final sign = switch (type) {
      TransactionType.buy when t.cashSourceId == null && !t.internalMove => 1,
      TransactionType.sell when t.cashTargetId == null && !t.internalMove => -1,
      TransactionType.income when t.cashTargetId != null => 1,
      TransactionType.expense when t.cashTargetId != null => -1,
      TransactionType.consume => -1,
      // Opening an existing debt records the liability as both endpoints.
      TransactionType.transferOut
          when t.cashSourceId != null && t.cashSourceId == t.cashTargetId =>
        -1,
      _ => 0,
    };
    if (sign == 0) continue;
    final rate = rateOf(t.currency);
    if (rate == null || !rate.isFinite || rate <= 0) return null;
    external += sign * t.amount * rate;
  }
  final profit = value - baseline.totalValue - external;
  return profit.isFinite ? profit : null;
}
