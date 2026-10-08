import 'dart:math';

import '../core/enums.dart';
import '../core/formats.dart';
import '../data/database.dart';

/// Geometric interpolation: value on [dayIndex] of a [start]..[end] range
/// spanning [totalDays], growing at a constant daily factor. Day 0 returns
/// [start], day totalDays returns [end].
double geometricInterpolate(
  double start,
  double end,
  int dayIndex,
  int totalDays,
) {
  if (totalDays <= 0 || dayIndex >= totalDays) return end;
  if (dayIndex <= 0) return start;
  if (start <= 0 || end <= 0) return end;
  final daily = pow(end / start, 1.0 / totalDays);
  return start * pow(daily, dayIndex);
}

/// Smooth (interpolated) history for holdings without a market source:
/// bank wealth and cash-management types.
///
/// Amount-based holdings replay their flows (income/expense/transfers) to
/// rebuild the principal timeline, then distribute the total gain across
/// segments weighted by principal x days, so money in/out days jump
/// correctly while each segment accrues smoothly. Share-based bank wealth
/// (no flows in practice) interpolates the price from cost to latest.
class SmoothHistoryCalculator {
  const SmoothHistoryCalculator();

  /// Daily values (yyyy-MM-dd -> value) for an amount-based holding.
  /// [flows] are the holding's related transactions (any order).
  ///
  /// [today] is the reference "now" used to detect whether [to] is a past
  /// day. When [to] is before [today], the all-time gain is distributed
  /// across the full timeline (inception -> [today]) and the sub-range
  /// [from, to] is read off, so flows that occurred after [to] do not leak
  /// into the window as phantom gains. Defaults to [DateTime.now].
  Map<String, double> amountHistory(
    HoldingRow h,
    List<TransactionRow> flows, {
    required DateTime from,
    required DateTime to,
    DateTime? today,
  }) {
    final result = <String, double>{};
    final current = h.quantity; // current amount (as of [today])
    final currentCost = h.costPrice > 0 ? h.costPrice : h.quantity;
    final totalGain = current - currentCost;

    final dayTo = _dayOf(to);
    final dayToday = _dayOf(today ?? DateTime.now());
    // When [to] is a past day, extend the timeline to [today] so that
    // post-[to] flows stay outside the window and the gain is spread over
    // the full accrual period rather than compressed into [from, to].
    final horizon = to.isBefore(dayToday) ? dayToday : dayTo;
    final segments = _amountSegments(h, flows, from: from, to: horizon);

    // Distribute the total gain by principal x days. Only positive-principal
    // spans participate in the denominator: a negative principal (a legacy
    // flow larger than the replayed balance, see [_segmentsFor]) contributes
    // zero gain and must NOT shrink the denominator, or every positive span
    // would be over-credited and the last-day pin would turn that excess
    // into a phantom loss/gain on the final day.
    var weightSum = 0.0;
    for (final s in segments) {
      if (s.principal > 0) weightSum += s.principal * s.days;
    }
    var cumGain = 0.0;
    for (final s in segments) {
      final positive = s.principal > 0;
      final segGain = weightSum <= 0 || !positive
          ? 0.0
          : totalGain * (s.principal * s.days) / weightSum;
      final startValue = s.principal + cumGain;
      final endValue = s.principal + cumGain + segGain;
      cumGain += segGain;
      // A span with no principal holds no money, so its days are zero. An
      // emptied account must not be handed the value it held before the
      // withdrawal (interpolating would do exactly that, and for a
      // zero-length span it would hand it the whole accrued gain).
      final empty = s.principal <= 0;
      for (
        var d = s.start;
        !d.isAfter(s.end) && !d.isAfter(dayTo);
        d = d.add(const Duration(days: 1))
      ) {
        final index = d.difference(s.start).inDays;
        result[todayKey(d)] = empty
            ? 0
            : geometricInterpolate(startValue, endValue, index, s.days);
      }
    }
    // When [to] is today (or later), the final day is exactly the current
    // amount. When [to] is a past day the interpolated value at [to] is
    // already consistent with the principal timeline (future flows excluded).
    if (!to.isBefore(dayToday)) {
      result[todayKey(dayTo)] = current;
    }
    return result;
  }

  /// Daily price for a share-based bank wealth holding: geometric
  /// interpolation from cost price to the latest price.
  double sharePrice(HoldingRow h, DateTime day, DateTime from, DateTime to) {
    if (h.latestPrice <= 0) return 0;
    final totalDays = to.difference(from).inDays;
    final index = day.difference(from).inDays;
    final start = h.costPrice > 0 ? h.costPrice : h.latestPrice;
    return geometricInterpolate(start, h.latestPrice, index, totalDays);
  }

  /// Daily principal (invested amount, yyyy-MM-dd -> value) for an
  /// amount-based holding, replayed from the flows. Cost moves with the
  /// balance on internal transfers (repayment/borrowing) that moved the
  /// cost, so historical days before a transfer keep the pre-transfer
  /// principal instead of the current one.
  ///
  /// A flow day belongs to the span that starts on it, not the one that ends
  /// on it, so a flow that empties the holding reports 0 for that day rather
  /// than the principal it held just before. Returning the pre-flow amount
  /// there made the whole transfer land in one day's cost while the day's
  /// value was already 0 — the 2026-09-18 "today's earning is -114,713.84"
  /// report (a full 余额宝 -> cash transfer, re-derived by the backfill on
  /// every cold start until the next price refresh overwrote the day).
  Map<String, double> amountPrincipal(
    HoldingRow h,
    List<TransactionRow> flows, {
    required DateTime from,
    required DateTime to,
    Map<int, double>? soldPrincipalById,
  }) {
    final result = <String, double>{};
    final dayTo = _dayOf(to);
    for (final s in _principalSegments(
      h,
      flows,
      from: from,
      to: to,
      soldPrincipalById: soldPrincipalById,
    )) {
      // A negative principal (legacy flow larger than the replayed balance)
      // must read as 0 on the cost side too, mirroring [amountHistory]'s
      // `empty` masking: otherwise the value sits at 0 while cost goes
      // negative on the way in and positive on the way out, producing a
      // paired phantom profit/loss across the negative span.
      final value = s.principal > 0 ? s.principal : 0.0;
      for (
        var d = s.start;
        !d.isAfter(s.end) && !d.isAfter(dayTo);
        d = d.add(const Duration(days: 1))
      ) {
        result[todayKey(d)] = value;
      }
    }
    // Symmetric to [amountHistory]'s last-day pin. The reverse segment walk
    // can end ABOVE the true invested amount when an intermediate dip got
    // clamped at 0 (a flow that momentarily exceeded the replayed principal):
    // the discarded excess then lives on in every later day's principal.
    // Without this pin the cost side stayed inflated while the value side
    // was already pinned to the live balance, so the day after the clamp the
    // product's Δ(value−cost) reported a phantom loss equal to the whole
    // clamped amount (2026-10-02 现金账户 −2,342.69 in the day-detail panel).
    if (!to.isBefore(_dayOf(DateTime.now()))) {
      result[todayKey(dayTo)] = h.costPrice > 0 ? h.costPrice : h.quantity;
    }
    return result;
  }

  /// Segments of constant principal between flow days, rebuilt by replaying
  /// the flows backwards from the current invested amount. Each segment
  /// carries its principal and the number of days it spans.
  ///
  /// Spans are kept even when their principal is 0. Spans are written in
  /// order and later ones overwrite earlier ones on the shared boundary day,
  /// so a span that zeroes the principal has to be present for the boundary
  /// day to report the post-flow principal; dropping it (the pre-2026-09-18
  /// behaviour) left that day carrying the *pre*-flow principal while the
  /// value side had already dropped to the current balance, which surfaced
  /// as one day of fake loss equal to the whole transfer.
  static List<({DateTime start, double principal, int days, DateTime end})>
  _amountSegments(
    HoldingRow h,
    List<TransactionRow> flows, {
    required DateTime from,
    required DateTime to,
  }) => _segmentsFor(
    h,
    flows,
    from: from,
    to: to,
    // The *value* curve mirrors the recorded cash amount: sell proceeds
    // credit it by the move recorded on the row (costMovedAmount for
    // post-fix rows, the raw amount for legacy ones).
    deltaOf: (h, t) => _flowDelta(h, t),
    current: h.costPrice > 0 ? h.costPrice : h.quantity,
  );

  /// Cost-side segments: like [_amountSegments], but a sell's proceeds
  /// credit the cash cost by the *sold principal* (see [_flowDelta]) so the
  /// unrealized gain of the sold lots stays on the cash side as gain, not
  /// re-booked as new cost. Legacy rows written before costMovedAmount
  /// existed carry only the raw amount; the caller supplies the sold
  /// principal captured by the flow replay via [soldPrincipalById].
  static List<({DateTime start, double principal, int days, DateTime end})>
  _principalSegments(
    HoldingRow h,
    List<TransactionRow> flows, {
    required DateTime from,
    required DateTime to,
    Map<int, double>? soldPrincipalById,
  }) => _segmentsFor(
    h,
    flows,
    from: from,
    to: to,
    deltaOf: (h, t) => _flowDelta(h, t, soldPrincipalById: soldPrincipalById),
    current: h.costPrice > 0 ? h.costPrice : h.quantity,
  );

  static List<({DateTime start, double principal, int days, DateTime end})>
  _segmentsFor(
    HoldingRow h,
    List<TransactionRow> flows, {
    required DateTime from,
    required DateTime to,
    required double Function(HoldingRow, TransactionRow) deltaOf,
    required double current,
  }) {
    final sorted = [...flows]
      ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
    final events = <({DateTime at, double delta})>[];
    var deltaSum = 0.0;
    for (final t in sorted) {
      final delta = deltaOf(h, t);
      if (delta == 0) continue;
      deltaSum += delta;
      events.add((at: _dayOf(t.occurredAt), delta: delta));
    }
    final startCost = current - deltaSum;

    // Segments: (startDate, principalAtStart, days, endDate).
    final segments =
        <({DateTime start, double principal, int days, DateTime end})>[];
    DateTime? segStart;
    var principal = startCost;
    for (final e in events) {
      final day = _dayOf(e.at);
      if (day.isAfter(to)) break;
      if (day.isBefore(from)) {
        // Flow before the window: just advance the principal.
        // NO clamp: clamping a negative excursion here discards money and
        // leaves every later segment's principal above the truth — the
        // 2026-10-02 现金账户 −2,342.69 phantom loss (value pinned to the
        // real balance while the cost stayed inflated).
        principal += e.delta;
        continue;
      }
      segStart ??= _dayOf(from);
      final end = day.isAfter(_dayOf(from)) ? day : _dayOf(from);
      final days = end.difference(segStart).inDays;
      if (days >= 0) {
        segments.add((
          start: segStart,
          principal: principal,
          days: days,
          end: end,
        ));
      }
      principal += e.delta;
      segStart = end;
    }
    segStart ??= _dayOf(from);
    final lastDays = _dayOf(to).difference(segStart).inDays;
    if (lastDays >= 0) {
      segments.add((
        start: segStart,
        principal: principal,
        days: lastDays,
        end: _dayOf(to),
      ));
    }
    return segments;
  }

  /// Principal delta a flow applies to [h]'s invested amount (0 when the
  /// flow does not touch the holding or the cost was not moved).
  ///
  /// The amount is read back from the row ([TransactionRow.costMovedAmount])
  /// rather than re-derived from `t.amount`, because the write side moves a
  /// *proportional* share of the principal: a transfer drains
  /// `costPrice x amount / balance` and the two only agree when the
  /// principal equals the balance or the account is fully drained. Deriving
  /// it from `amount` made the back-computed pre-flow principal come out off
  /// by the account's unrealized gain, shifting every earlier day of a
  /// rebuilt history. Rows written before the column existed have no value;
  /// they keep the legacy `amount` behaviour.
  ///
  /// A sell's proceeds credited to this holding are an exception: the cash
  /// account must gain the *sold principal* (its own unrealized gain must
  /// stay on the cash side), not the full proceeds. Rows recorded before
  /// `costMovedAmount` existed carry only [TransactionRow.amount], so the
  /// caller supplies the sold principal via [soldPrincipalById]
  /// (transaction id -> principal) when it can derive it (a flow replay).
  static double _flowDelta(
    HoldingRow h,
    TransactionRow t, {
    Map<int, double>? soldPrincipalById,
  }) {
    final type = TransactionType.fromStorage(t.type);
    final moved = t.costMovedAmount ?? t.amount;
    switch (type) {
      case TransactionType.income:
        if (t.cashTargetId == h.id) return moved;
      case TransactionType.expense:
        if (t.cashTargetId == h.id) return -moved;
      case TransactionType.transferIn || TransactionType.transferOut:
        if (!t.costMoved) return 0;
        if (t.cashSourceId == h.id) return -moved;
        if (t.cashTargetId == h.id) return moved;
      case TransactionType.buy:
        // Buy linkage debits the funding cash holding's invested amount
        // (the "record buy with a funding source" flow).
        if (t.cashSourceId == h.id) return -moved;
      case TransactionType.sell:
        // Sell proceeds credited to a cash holding move its invested
        // amount by the *sold principal* (legacy rows without
        // costMovedAmount fall back to the principal captured by the
        // replay; the raw amount would re-book the sold gain as cash cost);
        // a redemption leg recorded on the amount-based holding itself
        // (funded buy / standalone redemption) debits it. Ignoring these
        // legs left the replayed balance/cost stuck at the pre-redemption
        // level until today (visible as a cliff).
        if (t.cashTargetId == h.id) {
          return t.costMovedAmount ?? soldPrincipalById?[t.id] ?? t.amount;
        }
        if (t.holdingId == h.id &&
            AssetType.fromStorage(h.assetType).isAmountBased) {
          return -moved;
        }
      case TransactionType.dividend ||
          TransactionType.consume ||
          TransactionType.split:
        return 0;
    }
    return 0;
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
}
