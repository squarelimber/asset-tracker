/// Invested-amount ("cost basis") helpers for amount-based holdings —
/// cash, deposits, cash-management products and 银行理财 whose quantity is
/// the current balance and whose `costPrice` stores the cumulative
/// principal invested.
///
/// Single source of truth for the "costPrice = 0 means never recorded"
/// fallback. The portfolio totals, the CSV export, the history replay and
/// the transaction writes must all agree on it, otherwise the same number
/// gets two readings and the difference shows up as a phantom profit.
library;

import '../core/enums.dart';
import '../data/database.dart';

/// Effective invested amount of an amount-based holding: the recorded
/// `costPrice`, or the balance itself when none was ever recorded (0 is
/// the column default, so it doubles as "unset").
///
/// Not meaningful for share-based holdings, where `costPrice` is a
/// per-unit cost (use `quantity * costPrice`).
double effectiveCostOf(HoldingRow h) => h.costPrice > 0 ? h.costPrice : h.quantity;

/// Invested amount that travels with [amount] when money moves out of an
/// amount-based holding: **proportional to the balance**, so the holding
/// keeps its principal-to-balance ratio (its unrealized-gain rate) and the
/// portfolio's total cost is exactly conserved.
///
/// Why this is not simply `amount`:
/// - The old rule (`costPrice + delta`, clamped at 0) broke conservation.
///   Moving out more than the recorded principal pinned `costPrice` to 0,
///   and the totals then re-read that 0 as "no cost recorded" and fell back
///   to the *whole remaining balance* — the portfolio's cost jumped by the
///   account's unrealized gain, which surfaced as a loss of that size on
///   the day of the transfer.
/// - Moving a flat [amount] of principal also distorts the return rate: an
///   account with 10,000 balance / 9,000 principal (11.1% gain) that ships
///   3,000 away would keep 7,000 / 6,000 (16.7%). Taking the same *share*
///   of the principal — 2,700 — keeps it at 11.1%.
///
/// A full drain therefore moves the whole principal (ratio = 1) and leaves
/// an explicit 0, which matches the balance going to 0.
///
/// Liabilities have no cost basis at all: money they send is fresh capital
/// and moves 1:1 (that is also what makes reversing a repayment exact, and
/// keeps borrowing P/L-neutral).
double movedCostOf(HoldingRow h, double amount) {
  if (!AssetType.fromStorage(h.assetType).isAmountBased) return amount;
  final balance = h.quantity;
  if (balance <= 0) return 0;
  final ratio = (amount.abs() / balance).clamp(0.0, 1.0);
  return effectiveCostOf(h) * ratio;
}
