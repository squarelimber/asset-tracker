import '../core/enums.dart';
import '../data/database.dart';

/// Per-asset-type breakdown entry.
class TypeBreakdown {
  const TypeBreakdown({required this.type, required this.marketValue, required this.cost});

  final AssetType type;
  final double marketValue;
  final double cost;

  double get profit => marketValue - cost;
  double get profitPct => cost == 0 ? 0 : profit / cost;
}

/// Aggregated portfolio figures computed from holdings.
class PortfolioSummary {
  const PortfolioSummary({
    required this.totalAssets,
    required this.totalLiabilities,
    required this.totalCost,
    required this.todayChange,
    required this.todayChangePct,
    required this.breakdown,
  });

  final double totalAssets;
  final double totalLiabilities;
  final double totalCost;
  final double todayChange;
  final double? todayChangePct;
  final List<TypeBreakdown> breakdown;

  double get netWorth => totalAssets - totalLiabilities;
  double get profit => totalAssets - totalCost;
  double get profitPct => totalCost == 0 ? 0 : profit / totalCost;
}

/// Pure portfolio math, unit-testable without widgets or DB.
class PortfolioCalculator {
  const PortfolioCalculator();

  /// Computes the summary from holdings and cached previous prices.
  ///
  /// [prevPriceBySymbol] maps symbol -> previous close (CNY) used to
  /// compute today's change. Holdings without a previous price are
  /// excluded from the change figure.
  PortfolioSummary compute(
    List<HoldingRow> holdings, {
    Map<String, double> prevPriceBySymbol = const {},
  }) {
    var assets = 0.0;
    var liabilities = 0.0;
    var cost = 0.0;
    var todayChange = 0.0;
    var prevTotal = 0.0;

    final byType = <AssetType, double>{};
    final costByType = <AssetType, double>{};

    for (final h in holdings) {
      final type = AssetType.fromStorage(h.assetType);
      // Amount-based assets: quantity = current amount, price is fixed at 1
      // and costPrice stores the cumulative invested amount.
      final marketValue =
          type.isAmountBased ? h.quantity : h.quantity * h.latestPrice;
      final holdingCost =
          type.isAmountBased ? (h.costPrice > 0 ? h.costPrice : h.quantity) : h.quantity * h.costPrice;
      if (type == AssetType.liability) {
        liabilities += marketValue;
        continue;
      }
      assets += marketValue;
      cost += holdingCost;
      byType[type] = (byType[type] ?? 0) + marketValue;
      costByType[type] = (costByType[type] ?? 0) + holdingCost;

      final symbol = h.symbol;
      final prev = (symbol != null && prevPriceBySymbol.containsKey(symbol))
          ? prevPriceBySymbol[symbol]
          : null;
      if (prev != null && prev > 0) {
        todayChange += (h.latestPrice - prev) * h.quantity;
        prevTotal += prev * h.quantity;
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

    return PortfolioSummary(
      totalAssets: assets,
      totalLiabilities: liabilities,
      totalCost: cost,
      todayChange: todayChange,
      todayChangePct: prevTotal == 0 ? null : todayChange / prevTotal,
      breakdown: breakdown,
    );
  }
}
