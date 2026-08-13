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
  Map<String, double> amountHistory(
    HoldingRow h,
    List<TransactionRow> flows, {
    required DateTime from,
    required DateTime to,
  }) {
    final result = <String, double>{};
    final current = h.quantity; // current amount
    final currentCost = h.costPrice > 0 ? h.costPrice : h.quantity;

    // Rebuild the principal timeline from flows (reversed from the current
    // invested amount).
    final sorted = [...flows]..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
    final events = <({DateTime at, double delta})>[];
    var deltaSum = 0.0;
    for (final t in sorted) {
      final delta = _flowDelta(h, t);
      if (delta == 0) continue;
      deltaSum += delta;
      events.add((at: _dayOf(t.occurredAt), delta: delta));
    }
    final startCost = (currentCost - deltaSum).clamp(0.0, double.infinity);
    final totalGain = current - currentCost;

    // Segments: (startDate, principalAtStart, days, endDate).
    // Final anchor is [to] with value = current.
    final segments = <({DateTime start, double principal, int days, DateTime end})>[];
    DateTime? segStart;
    var principal = startCost;
    for (final e in events) {
      final day = _dayOf(e.at);
      if (day.isAfter(to)) break;
      if (day.isBefore(from)) {
        // Flow before the window: just advance the principal.
        principal = (principal + e.delta).clamp(0.0, double.infinity);
        continue;
      }
      segStart ??= _dayOf(from);
      final end = day.isAfter(_dayOf(from)) ? day : _dayOf(from);
      final days = end.difference(segStart).inDays;
      if (days >= 0 && principal > 0) {
        segments.add((
          start: segStart,
          principal: principal,
          days: days,
          end: end,
        ));
      }
      principal = (principal + e.delta).clamp(0.0, double.infinity);
      segStart = end;
    }
    segStart ??= _dayOf(from);
    final lastDays = _dayOf(to).difference(segStart).inDays;
    if (lastDays >= 0 && principal > 0) {
      segments.add((
        start: segStart,
        principal: principal,
        days: lastDays,
        end: _dayOf(to),
      ));
    }

    // Distribute the total gain by principal x days.
    var weightSum = 0.0;
    for (final s in segments) {
      weightSum += s.principal * s.days;
    }
    var cumGain = 0.0;
    final dayTo = _dayOf(to);
    for (final s in segments) {
      final segGain = weightSum <= 0 ? 0.0 : totalGain * (s.principal * s.days) / weightSum;
      final startValue = s.principal + cumGain;
      final endValue = s.principal + cumGain + segGain;
      cumGain += segGain;
      for (var d = s.start;
          !d.isAfter(s.end) && !d.isAfter(dayTo);
          d = d.add(const Duration(days: 1))) {
        final index = d.difference(s.start).inDays;
        result[todayKey(d)] = geometricInterpolate(
          startValue,
          endValue,
          index,
          s.days,
        );
      }
    }
    // Ensure the final day is exactly the current amount.
    result[todayKey(dayTo)] = current;
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

  /// Principal delta a flow applies to [h]'s invested amount (0 when the
  /// flow does not touch the holding or the cost was not moved).
  static double _flowDelta(HoldingRow h, TransactionRow t) {
    final type = TransactionType.fromStorage(t.type);
    switch (type) {
      case TransactionType.income:
        if (t.cashTargetId == h.id) return t.amount;
      case TransactionType.expense:
        if (t.cashTargetId == h.id) return -t.amount;
      case TransactionType.transferIn || TransactionType.transferOut:
        if (!t.costMoved) return 0;
        if (t.cashSourceId == h.id) return -t.amount;
        if (t.cashTargetId == h.id) return t.amount;
      case TransactionType.buy ||
            TransactionType.sell ||
            TransactionType.dividend ||
            TransactionType.consume ||
            TransactionType.split:
        return 0;
    }
    return 0;
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
}
