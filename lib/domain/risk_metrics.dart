import 'dart:math' as math;

import '../core/formats.dart';
import '../data/database.dart';

/// Estimates risk-adjusted return from a recent, uninterrupted series of
/// daily CNY snapshots. This is not a time-weighted return: intraday cash
/// flows and their exact valuation times cannot be reconstructed reliably.
/// Manually smoothed asset values and approximated historical FX rates can
/// also understate or distort volatility. All days with any recorded flow
/// are excluded, and flows, missing dates and unexplained cost changes break
/// the series. In particular, mixed vintages of foreign-exchange conversions
/// cannot safely be mistaken for a return.
class RiskMetricsEstimate {
  const RiskMetricsEstimate({
    required this.sharpe,
    required this.annualizedVolatility,
    required this.sampleCount,
    required this.startDate,
    required this.endDate,
    required this.unavailableReason,
    this.interruptedDate,
    this.interruptionReason,
  });

  final double? sharpe;
  final double? annualizedVolatility;
  final int sampleCount;
  final String? startDate;
  final String? endDate;
  final String? unavailableReason;
  final String? interruptedDate;
  final String? interruptionReason;
}

/// [annualRiskFreeRate] is a fraction, so 1% is 0.01. Uses at most 365
/// consecutive, completed calendar-day returns, with sample standard
/// deviation and square-root-of-365 scaling. This annualization is an
/// approximation and may be biased when returns are serially correlated.
RiskMetricsEstimate estimateRiskMetrics(
  List<SnapshotRow> snapshots,
  List<TransactionRow> transactions, {
  required double annualRiskFreeRate,
  DateTime? now,
}) {
  final today = todayKey(now ?? DateTime.now());
  final flows = transactions
      .map((t) => todayKey(t.occurredAt.toLocal()))
      .toSet();
  final ordered =
      snapshots
          .where(
            (s) =>
                s.currency.toUpperCase() == 'CNY' &&
                s.date.compareTo(today) < 0,
          )
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));

  // A backdated or edited transaction can invalidate every later snapshot
  // until history is rebuilt. Track the most recent update among flows that
  // had already occurred as of each snapshot, including old flow dates.
  final flowUpdates = [
    for (final t in transactions)
      (day: todayKey(t.occurredAt.toLocal()), updatedAt: t.updatedAt),
  ]..sort((a, b) => a.day.compareTo(b.day));
  final stale = <bool>[];
  DateTime? latestUpdate;
  var flowIndex = 0;
  for (final snapshot in ordered) {
    while (flowIndex < flowUpdates.length &&
        flowUpdates[flowIndex].day.compareTo(snapshot.date) <= 0) {
      final updatedAt = flowUpdates[flowIndex].updatedAt;
      if (latestUpdate == null || updatedAt.isAfter(latestUpdate)) {
        latestUpdate = updatedAt;
      }
      flowIndex++;
    }
    stale.add(latestUpdate != null && latestUpdate.isAfter(snapshot.createdAt));
  }

  DateTime? parseDay(String key) {
    final date = DateTime.tryParse(key);
    if (date == null || todayKey(date) != key) return null;
    return DateTime.utc(date.year, date.month, date.day);
  }

  final returns = <double>[];
  String? startDate;
  String? endDate;
  String? interruptedDate;
  String? interruptionReason;
  for (var i = 1; i < ordered.length; i++) {
    final previous = ordered[i - 1];
    final current = ordered[i];
    final before = parseDay(previous.date);
    final after = parseDay(current.date);
    final previousAssets = previous.totalValue + previous.liabilities;
    final currentAssets = current.totalValue + current.liabilities;
    // Without an observed transaction, a cost-basis change can come from a
    // manual edit, an unrecorded opening or a different fallback FX rate.
    // None can safely be attributed to investment performance. Allow only
    // numerical rounding noise in the otherwise unchanged principal.
    final costTolerance = math.max(
      1e-6,
      math.max(previous.totalCost.abs(), current.totalCost.abs()) * 1e-10,
    );
    String? interruption;
    var interruptionDay = current.date;
    if (before == null || after == null) {
      interruption = '快照日期无效';
    } else if (after.difference(before).inDays != 1) {
      interruption = '缺少每日快照';
      interruptionDay = todayKey(after.subtract(const Duration(days: 1)));
    } else if (flows.contains(current.date)) {
      interruption = '当天存在交易流水';
    } else if (stale[i - 1] || stale[i]) {
      interruption = '流水更新后尚未重建快照';
    } else if (!previousAssets.isFinite ||
        previousAssets <= 0 ||
        !currentAssets.isFinite ||
        currentAssets <= 0) {
      interruption = '资产估值无效';
    } else if (!previous.totalCost.isFinite ||
        !current.totalCost.isFinite ||
        (current.totalCost - previous.totalCost).abs() > costTolerance) {
      interruption = '本金变化缺少可核对的流水';
    }
    if (interruption != null) {
      interruptedDate = interruptionDay;
      interruptionReason = interruption;
      returns.clear();
      startDate = null;
      endDate = null;
      continue;
    }
    final r =
        ((currentAssets - current.totalCost) -
            (previousAssets - previous.totalCost)) /
        previousAssets;
    if (!r.isFinite) {
      interruptedDate = current.date;
      interruptionReason = '日收益无法计算';
      returns.clear();
      startDate = null;
      endDate = null;
      continue;
    }
    startDate ??= previous.date;
    endDate = current.date;
    returns.add(r);
    if (returns.length > 365) {
      returns.removeAt(0);
      startDate = ordered[i - returns.length].date;
    }
  }

  RiskMetricsEstimate unavailable(String reason, {double? volatility}) =>
      RiskMetricsEstimate(
        sharpe: null,
        annualizedVolatility: volatility,
        sampleCount: returns.length,
        startDate: startDate,
        endDate: endDate,
        unavailableReason: reason,
        interruptedDate: interruptedDate,
        interruptionReason: interruptionReason,
      );
  if (ordered.length < 2) {
    interruptedDate = ordered.lastOrNull?.date;
    interruptionReason = '至少需要两天可比较的快照';
  }
  if (!annualRiskFreeRate.isFinite || annualRiskFreeRate <= -1) {
    return unavailable('无风险年利率无效');
  }
  if (returns.length < 30) return unavailable('连续有效数据不足 30 天');
  final mean = returns.reduce((a, b) => a + b) / returns.length;
  final variance =
      returns.fold<double>(0, (sum, r) => sum + (r - mean) * (r - mean)) /
      (returns.length - 1);
  final deviation = math.sqrt(variance);
  if (!deviation.isFinite || deviation <= 0) {
    return unavailable(
      '收益波动为零，无法计算夏普比率',
      volatility: deviation.isFinite ? 0 : null,
    );
  }
  final dailyRiskFree =
      math.pow(1 + annualRiskFreeRate, 1 / 365).toDouble() - 1;
  final annualizedVolatility = deviation * math.sqrt(365);
  final sharpe = (mean - dailyRiskFree) / deviation * math.sqrt(365);
  if (!sharpe.isFinite || !annualizedVolatility.isFinite) {
    return unavailable('收益数据无法计算');
  }
  return RiskMetricsEstimate(
    sharpe: sharpe,
    annualizedVolatility: annualizedVolatility,
    sampleCount: returns.length,
    startDate: startDate,
    endDate: endDate,
    unavailableReason: null,
    interruptedDate: interruptedDate,
    interruptionReason: interruptionReason,
  );
}
