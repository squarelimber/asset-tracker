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

  TradeStats compute(List<TransactionRow> txns, List<HoldingRow> holdings) {
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

      switch (type) {
        case TransactionType.buy:
          bought += t.amount;
          monthly[month] = flow - t.amount;
        case TransactionType.sell:
          sold += t.amount;
          monthly[month] = flow + t.amount;
          final unitCost = costByHolding[t.holdingId] ?? 0;
          final qty = t.quantity ?? 0;
          final price = t.price ?? 0;
          realized += (price - unitCost) * qty;
        case TransactionType.income:
          income += t.amount;
          monthly[month] = flow + t.amount;
        case TransactionType.expense:
          expense += t.amount;
          monthly[month] = flow - t.amount;
        case TransactionType.dividend:
          dividend += t.amount;
          monthly[month] = flow + t.amount;
        case TransactionType.transferIn || TransactionType.transferOut:
          break; // internal movement, no net-worth effect
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
}
