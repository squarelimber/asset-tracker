/// Reinterpreting a holding's stored numbers when an edit crosses the
/// amount-based boundary (现金/银行存款/活期理财 ↔ 份额型).
///
/// The two sides store *different meanings* in the same three columns:
/// - amount-based: quantity = current balance, costPrice = cumulative
///   invested, latestPrice fixed at 1;
/// - share-based: quantity = shares, costPrice = per-unit cost, latestPrice
///   = NAV.
///
/// The edit dialog used to keep the digits and swap the labels, so 朝朝宝's
/// 50000 元 of balance became 50000 元/份 of unit cost on a 银行存款 → 银行理财
/// switch — the holding then reported 成本 = 50000 份 × 50000 元/份 = 25 亿 and
/// a ~25 亿 loss, and every history rebuild projected that broken unit cost
/// onto the whole net-worth curve. This module is the conversion the dialog
/// must apply the moment the type crosses the boundary, so the same market
/// value and the same cost survive the switch and the profit line stays
/// continuous.
library;

import '../core/enums.dart';

/// The holding's numbers expressed in the NEW type's semantics.
class HoldingTypeConversion {
  const HoldingTypeConversion({
    required this.quantity,
    required this.costPrice,
    required this.latestPrice,
  });

  /// New-semantics quantity: 份额 (share-based) or 余额 (amount-based).
  final double quantity;

  /// New-semantics cost: 单位成本 (share-based) or 累计投入 (amount-based).
  final double costPrice;

  /// New-semantics latest price: 净值 (share-based) or 1 (amount-based).
  final double latestPrice;
}

/// Converts [quantity] / [costPrice] / [latestPrice] from [from]'s semantics
/// to [to]'s. Both sides of every conversion are derived from the CURRENT
/// numbers, so market value and cost are preserved:
///
/// - amount → share (e.g. 银行存款 → 银行理财): the shares stay numerically
///   equal to the balance (a money-market/wealth product bought at NAV 1 has
///   份额 == 金额), the per-unit cost becomes 累计投入 ÷ 份额 (using the
///   effective invested amount, so an unrecorded principal becomes a unit
///   cost of 1), and the latest price keeps its placeholder 1 for the user
///   to replace with the real NAV.
/// - share → amount (e.g. 银行理财 → 现金): the balance becomes 份额 × 净值
///   (the market value), the cumulative invested becomes 份额 × 单位成本, and
///   the latest price returns to 1.
///
/// Switching within the same side of the boundary (现金 → 银行存款, 基金 →
/// 股票) changes no semantics and returns null — nothing to convert.
///
/// Returns null when the conversion is not trustworthy (no shares to divide
/// by on amount → share, no NAV to value the balance on share → amount); the
/// caller must then keep the old digits and ask the user to fill the new
/// semantics by hand rather than invent numbers.
HoldingTypeConversion? convertHoldingTypeSemantics({
  required AssetType from,
  required AssetType to,
  required double quantity,
  required double costPrice,
  required double latestPrice,
}) {
  if (from.isAmountBased && !to.isAmountBased) {
    if (!(quantity > 0)) return null; // no balance to turn into shares
    final invested = costPrice > 0 ? costPrice : quantity;
    return HoldingTypeConversion(
      quantity: quantity, // balance → shares (same digits at NAV 1)
      costPrice: invested / quantity, // 累计投入 → 单位成本
      latestPrice: latestPrice > 0 ? latestPrice : 1, // keep 1 as placeholder
    );
  }
  if (!from.isAmountBased && to.isAmountBased) {
    if (!(latestPrice > 0)) return null; // no NAV → cannot value the balance
    return HoldingTypeConversion(
      quantity: quantity * latestPrice, // 份额 × 净值 → 余额 (market value)
      costPrice: quantity * costPrice, // 份额 × 单位成本 → 累计投入
      latestPrice: 1,
    );
  }
  return null; // same side of the boundary: semantics unchanged
}