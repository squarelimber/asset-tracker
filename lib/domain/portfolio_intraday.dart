import '../core/enums.dart';
import '../core/formats.dart';
import '../core/market_session.dart';
import '../core/symbols.dart';
import '../data/database.dart';

/// Treat the clock fields as China market time regardless of device zone.
DateTime chinaMarketTime(DateTime instant) =>
    instant.toUtc().add(const Duration(hours: 8));

bool prefersTodayTrend(DateTime instant) {
  final session = aShareSession(chinaMarketTime(instant));
  return session == MarketSession.open || session == MarketSession.lunch;
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
      TransactionType.buy when t.cashSourceId == null => 1,
      TransactionType.sell when t.cashTargetId == null => -1,
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
