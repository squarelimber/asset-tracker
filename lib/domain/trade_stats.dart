import '../core/enums.dart';
import '../data/database.dart';

/// Aggregate trade statistics over all transactions.
class TradeStats {
  const TradeStats({
    required this.boughtTotal,
    required this.soldTotal,
    required this.incomeTotal,
    required this.expenseTotal,
    required this.dividendTotal,
    required this.realizedProfit,
    required this.monthlyCashflow,
  });

  final double boughtTotal;
  final double soldTotal;
  final double incomeTotal;
  final double expenseTotal;
  final double dividendTotal;

  /// Realized gains from sells (estimated with current unit cost).
  final double realizedProfit;

  /// 'yyyy-MM' -> net cash flow for that month.
  final Map<String, double> monthlyCashflow;

  /// Net cash flow: money in minus money out (transfers excluded, since
  /// they move money between own holdings and do not change net worth).
  double get cashflow =>
      incomeTotal + dividendTotal + soldTotal - expenseTotal - boughtTotal;

  /// Count of transactions.
  int get count => monthlyCashflow.values.fold(0, (a, b) => a) + monthlyCashflow.length;
}

/// Pure trade statistics math, unit-testable.
class TradeStatsCalculator {
  const TradeStatsCalculator();

  /// [cnyRates] converts each transaction's amount into CNY (default 1).
  TradeStats compute(
    List<TransactionRow> txns,
    List<HoldingRow> holdings, {
    Map<String, double> cnyRates = const {},
  }) {
    double rateOf(String currency) {
      final rate = cnyRates[currency.toUpperCase()];
      return (rate == null || rate <= 0) ? 1 : rate;
    }

    var bought = 0.0;
    var sold = 0.0;
    var income = 0.0;
    var expense = 0.0;
    var dividend = 0.0;
    final monthly = <String, double>{};

    final costByHolding = <int, double>{
      for (final h in holdings) h.id: h.costPrice,
    };
    var realized = 0.0;

    for (final t in txns) {
      final type = TransactionType.fromStorage(t.type);
      final month = '${t.occurredAt.year}-${t.occurredAt.month.toString().padLeft(2, '0')}';
      final flow = monthly[month] ?? 0.0;
      final amount = t.amount * rateOf(t.currency);

      switch (type) {
        case TransactionType.buy:
          bought += amount;
          monthly[month] = flow - amount;
        case TransactionType.sell:
          sold += amount;
          monthly[month] = flow + amount;
          final unitCost = costByHolding[t.holdingId] ?? 0;
          final qty = t.quantity ?? 0;
          final price = t.price ?? 0;
          realized += (price - unitCost) * qty * rateOf(t.currency);
        case TransactionType.income:
          income += amount;
          monthly[month] = flow + amount;
        case TransactionType.expense:
          expense += amount;
          monthly[month] = flow - amount;
        case TransactionType.dividend:
          dividend += amount;
          monthly[month] = flow + amount;
        case TransactionType.transferIn || TransactionType.transferOut:
          break; // internal movement, no net-worth effect
        case TransactionType.consume:
          break; // liability change, not a cash flow
        case TransactionType.split:
          break; // share adjustment, not a cash flow
      }
    }

    return TradeStats(
      boughtTotal: bought,
      soldTotal: sold,
      incomeTotal: income,
      expenseTotal: expense,
      dividendTotal: dividend,
      realizedProfit: realized,
      monthlyCashflow: monthly,
    );
  }

  /// Per-holding realized profit from sell transactions, using the same
  /// formula as [compute]: (sell.price - unit cost at the time of the sell)
  /// x sell.quantity, converted to CNY via [cnyRates].
  ///
  /// [costByHolding] maps holding id to the unit cost that applied when the
  /// shares were sold (a fully sold-out holding keeps its last costPrice).
  /// Returns only holdings that have at least one sell.
  static Map<int, double> realizedProfitByHolding(
    List<TransactionRow> txns,
    Map<int, double> costByHolding, {
    Map<String, double> cnyRates = const {},
  }) {
    double rateOf(String currency) {
      final rate = cnyRates[currency.toUpperCase()];
      return (rate == null || rate <= 0) ? 1 : rate;
    }

    final result = <int, double>{};
    for (final t in txns) {
      if (TransactionType.fromStorage(t.type) != TransactionType.sell) continue;
      final holdingId = t.holdingId;
      if (holdingId == null) continue;
      final unitCost = costByHolding[holdingId] ?? 0;
      final qty = t.quantity ?? 0;
      final price = t.price ?? 0;
      result[holdingId] =
          (result[holdingId] ?? 0) + (price - unitCost) * qty * rateOf(t.currency);
    }
    return result;
  }

  /// Date of the most recent sell transaction, optionally filtered to a
  /// single holding. Null when no matching sell exists.
  static DateTime? lastSellDate(List<TransactionRow> txns, {int? holdingId}) {
    DateTime? latest;
    for (final t in txns) {
      if (TransactionType.fromStorage(t.type) != TransactionType.sell) continue;
      if (holdingId != null && t.holdingId != holdingId) continue;
      if (latest == null || t.occurredAt.isAfter(latest)) latest = t.occurredAt;
    }
    return latest;
  }
}
