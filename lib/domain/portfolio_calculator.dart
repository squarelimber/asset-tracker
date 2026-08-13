import '../core/enums.dart';
import '../core/symbols.dart';
import '../data/database.dart';

/// Per-asset-type breakdown entry (CNY-converted values).
class TypeBreakdown {
  const TypeBreakdown({required this.type, required this.marketValue, required this.cost});

  final AssetType type;
  final double marketValue;
  final double cost;

  double get profit => marketValue - cost;
  double get profitPct => cost == 0 ? 0 : profit / cost;
}

/// Per-risk-tier breakdown entry.
class RiskBreakdown {
  const RiskBreakdown({required this.risk, required this.marketValue, required this.cost});

  final RiskLevel risk;
  final double marketValue;
  final double cost;
}

/// Aggregated portfolio figures computed from holdings.
/// All amounts are in CNY (per-holding currency converted via [cnyRates]).
class PortfolioSummary {
  const PortfolioSummary({
    required this.totalAssets,
    required this.totalLiabilities,
    required this.totalCost,
    required this.todayChange,
    required this.todayChangePct,
    required this.breakdown,
    this.riskBreakdown = const [],
    this.realizedProfit = 0,
  });

  final double totalAssets;
  final double totalLiabilities;
  final double totalCost;
  final double todayChange;
  final double? todayChangePct;
  final List<TypeBreakdown> breakdown;

  /// Market value per risk tier.
  final List<RiskBreakdown> riskBreakdown;

  /// Sum of realized gains from sell transactions (approximate: computed
  /// with the current unit cost when the average cost may have changed).
  final double realizedProfit;

  double get netWorth => totalAssets - totalLiabilities;
  double get profit => totalAssets - totalCost;
  double get profitPct => totalCost == 0 ? 0 : profit / totalCost;

  /// Unrealized profit (floating) = total profit minus realized gains.
  double get unrealizedProfit => profit - realizedProfit;
}

/// Pure portfolio math, unit-testable without widgets or DB.
class PortfolioCalculator {
  const PortfolioCalculator();

  /// Computes the summary from holdings and cached previous prices.
  ///
  /// [prevPriceBySymbol] maps symbol -> previous close price (same currency
  /// as the holding) used to compute today's change.
  /// [cnyRates] maps ISO currency code -> CNY per unit (default 1 = CNY),
  /// applied to convert every holding's market value and cost into CNY.
  /// [sellTransactions] (optional) feeds the realized-profit estimate.
  PortfolioSummary compute(
    List<HoldingRow> holdings, {
    Map<String, double> prevPriceBySymbol = const {},
    Map<String, double> cnyRates = const {},
    List<TransactionRow> sellTransactions = const [],
  }) {
    var assets = 0.0;
    var liabilities = 0.0;
    var cost = 0.0;
    var todayChange = 0.0;
    var prevTotal = 0.0;

    final byType = <AssetType, double>{};
    final costByType = <AssetType, double>{};
    final byRisk = <RiskLevel, double>{};
    final costByRisk = <RiskLevel, double>{};

    for (final h in holdings) {
      final type = AssetType.fromStorage(h.assetType);
      final risk = RiskLevel.fromStorage(h.riskLevel) ??
          RiskLevel.autoOf(type);
      final rate = valueRateOf(h, cnyRates);
      // Amount-based assets: quantity = current amount, price fixed at 1 and
      // costPrice stores the cumulative invested amount (in the currency).
      final marketValue =
          (type.isAmountBased ? h.quantity : h.quantity * h.latestPrice) * rate;
      final holdingCost = (type.isAmountBased
              ? (h.costPrice > 0 ? h.costPrice : h.quantity)
              : h.quantity * h.costPrice) *
          costRateOf(h, cnyRates);
      if (type == AssetType.liability) {
        liabilities += marketValue;
        continue;
      }
      assets += marketValue;
      cost += holdingCost;
      byType[type] = (byType[type] ?? 0) + marketValue;
      costByType[type] = (costByType[type] ?? 0) + holdingCost;
      byRisk[risk] = (byRisk[risk] ?? 0) + marketValue;
      costByRisk[risk] = (costByRisk[risk] ?? 0) + holdingCost;

      final symbol = h.symbol;
      final prev = (symbol != null && prevPriceBySymbol.containsKey(symbol))
          ? prevPriceBySymbol[symbol]
          : null;
      if (prev != null && prev > 0) {
        todayChange += (h.latestPrice - prev) * h.quantity * rate;
        prevTotal += prev * h.quantity * rate;
      }
    }

    final breakdown = [
      for (final entry in byType.entries)
        TypeBreakdown(
          type: entry.key,
          marketValue: entry.value,
          cost: costByType[entry.key] ?? 0,
        ),
    ]..sort((a, b) => b.marketValue.compareTo(a.marketValue));

    final riskBreakdown = [
      for (final entry in byRisk.entries)
        RiskBreakdown(
          risk: entry.key,
          marketValue: entry.value,
          cost: costByRisk[entry.key] ?? 0,
        ),
    ]..sort((a, b) => b.marketValue.compareTo(a.marketValue));

    final realized = _realizedProfit(holdings, sellTransactions);

    return PortfolioSummary(
      totalAssets: assets,
      totalLiabilities: liabilities,
      totalCost: cost,
      todayChange: todayChange,
      todayChangePct: prevTotal == 0 ? null : todayChange / prevTotal,
      breakdown: breakdown,
      riskBreakdown: riskBreakdown,
      realizedProfit: realized,
    );
  }

  /// Sum of realized gains over all sell transactions.
  /// Estimated with the holding's current unit cost, which is exact when no
  /// purchase happened after the sell (moving average otherwise approximates).
  double _realizedProfit(List<HoldingRow> holdings, List<TransactionRow> sells) {
    if (sells.isEmpty) return 0;
    final costByHolding = <int, double>{
      for (final h in holdings) h.id: h.costPrice,
    };
    var total = 0.0;
    for (final t in sells) {
      final holdingId = t.holdingId;
      if (holdingId == null) continue;
      final unitCost = costByHolding[holdingId] ?? 0;
      final qty = t.quantity ?? 0;
      final price = t.price ?? 0;
      total += (price - unitCost) * qty;
    }
    return total;
  }
}
