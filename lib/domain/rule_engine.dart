import 'dart:convert';

import '../core/enums.dart';
import '../core/symbols.dart';
import '../data/database.dart';
import 'holding_category.dart';
import 'portfolio_calculator.dart';

enum AlertLevel { info, warning, danger }

class AlertResult {
  const AlertResult({
    required this.ruleId,
    required this.level,
    required this.title,
    required this.message,
    this.dedupPrefix,
  });

  final int ruleId;
  final AlertLevel level;
  final String title;
  final String message;

  /// Stable message prefix for separate subjects under one rule, such as
  /// holdings that happen to have the same display name.
  final String? dedupPrefix;
}

/// Everything a rule needs to evaluate.
class RuleContext {
  RuleContext({
    required this.summary,
    required this.holdings,
    this.priceCache = const {},
    this.cnyRates = const {},
    this.targetAllocation = const {},
    DateTime? now,
  }) : now = now ?? DateTime.now();

  final PortfolioSummary summary;
  final List<HoldingRow> holdings;

  /// symbol -> cached price (for per-holding daily change).
  final Map<String, PriceCacheRow> priceCache;

  /// currency -> CNY rate, so foreign-currency holdings are measured
  /// against the CNY total instead of mixing raw foreign amounts in.
  final Map<String, double> cnyRates;

  /// Target percentages, in the same 0–100 units as the allocation editor.
  final Map<AssetCategory, double> targetAllocation;
  final DateTime now;
}

/// A single evaluator per [AlertRuleType].
abstract class RuleEvaluator {
  const RuleEvaluator();

  AlertRuleType get type;

  List<AlertResult> evaluate(AlertRuleRow rule, RuleContext ctx);

  /// Parses the rule params JSON safely.
  Map<String, dynamic> paramsOf(AlertRuleRow rule) {
    try {
      final decoded = jsonDecode(rule.params);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}

// ---------------------------------------------------------------------------
// Concentration risk: single holding exceeds threshold of total assets.
// ---------------------------------------------------------------------------

class ConcentrationEvaluator extends RuleEvaluator {
  const ConcentrationEvaluator();

  @override
  AlertRuleType get type => AlertRuleType.concentration;

  @override
  List<AlertResult> evaluate(AlertRuleRow rule, RuleContext ctx) {
    final params = paramsOf(rule);
    final threshold = (params['threshold'] as num?)?.toDouble() ?? 0.3;
    final total = ctx.summary.totalAssets;
    if (total <= 0) return const [];

    final results = <AlertResult>[];
    for (final h in ctx.holdings) {
      if (AssetType.fromStorage(h.assetType) == AssetType.liability) continue;
      final type = AssetType.fromStorage(h.assetType);
      final marketValue =
          (type.isAmountBased ? h.quantity : h.quantity * h.latestPrice) *
          valueRateOf(h, ctx.cnyRates);
      final ratio = marketValue / total;
      if (ratio > threshold) {
        results.add(
          AlertResult(
            ruleId: rule.id,
            level: ratio > threshold * 1.2
                ? AlertLevel.danger
                : AlertLevel.warning,
            title: '集中度风险',
            dedupPrefix: '持仓 #${h.id} ',
            message:
                '持仓 #${h.id} 「${h.name}」市值 ${_money(marketValue)} 占总资产 ${_pct(ratio)}，'
                '超过阈值 ${_pct(threshold)}',
          ),
        );
      }
    }
    return results;
  }
}

// ---------------------------------------------------------------------------
// Equity allocation ratio: equity share deviates from target range.
// ---------------------------------------------------------------------------

class AssetRatioEvaluator extends RuleEvaluator {
  const AssetRatioEvaluator();

  @override
  AlertRuleType get type => AlertRuleType.assetRatio;

  @override
  List<AlertResult> evaluate(AlertRuleRow rule, RuleContext ctx) {
    final params = paramsOf(rule);
    // Existing rules omit followTarget and retain their original custom value.
    final target = params['followTarget'] == true
        ? (ctx.targetAllocation[AssetCategory.equity] ?? 40) / 100
        : (params['target'] as num?)?.toDouble() ?? 0.6;
    final tolerance = (params['tolerance'] as num?)?.toDouble() ?? 0.15;
    final total = ctx.summary.totalAssets;
    if (total <= 0) return const [];

    // Equity = every holding whose *effective* allocation category is 权益
    // (single source of truth; do not keep a local type set that can drift).
    // The manual category override counts: a 商品ETF filed under 商品 must
    // not inflate the equity ratio.
    var equity = 0.0;
    for (final h in ctx.holdings) {
      if (effectiveCategoryOf(h) == AssetCategory.equity) {
        equity += h.quantity * h.latestPrice * valueRateOf(h, ctx.cnyRates);
      }
    }
    final ratio = equity / total;
    final lower = target - tolerance;
    final upper = target + tolerance;

    if (ratio < lower || ratio > upper) {
      final direction = ratio < target ? '偏低' : '偏高';
      return [
        AlertResult(
          ruleId: rule.id,
          level: AlertLevel.warning,
          title: '配置比例偏离',
          message:
              '权益类资产占比 ${_pct(ratio)}，目标 ${_pct(target)}'
              '（允许 ${_pct(lower)}~${_pct(upper)}），当前$direction',
        ),
      ];
    }
    return const [];
  }
}

// ---------------------------------------------------------------------------
// Daily drawdown: total portfolio drops more than threshold in a day.
// ---------------------------------------------------------------------------

class DrawdownEvaluator extends RuleEvaluator {
  const DrawdownEvaluator();

  @override
  AlertRuleType get type => AlertRuleType.drawdown;

  @override
  List<AlertResult> evaluate(AlertRuleRow rule, RuleContext ctx) {
    final params = paramsOf(rule);
    final threshold = (params['threshold'] as num?)?.toDouble() ?? 0.03;
    final changePct = ctx.summary.todayChangePct;
    if (changePct == null || changePct >= 0) return const [];
    final drop = -changePct;
    if (drop > threshold) {
      return [
        AlertResult(
          ruleId: rule.id,
          level: AlertLevel.danger,
          title: '单日跌幅预警',
          message: '今日资产下跌 ${_pct(drop)}，超过预警阈值 ${_pct(threshold)}',
        ),
      ];
    }
    return const [];
  }
}

// ---------------------------------------------------------------------------
// Cashflow reminder: recurring monthly day (loan, auto-invest...).
// ---------------------------------------------------------------------------

class CashflowEvaluator extends RuleEvaluator {
  const CashflowEvaluator();

  @override
  AlertRuleType get type => AlertRuleType.cashflow;

  @override
  List<AlertResult> evaluate(AlertRuleRow rule, RuleContext ctx) {
    final params = paramsOf(rule);
    final day = ((params['dayOfMonth'] as num?)?.toInt() ?? 1).clamp(1, 31);
    final label = params['label']?.toString() ?? '现金流事项';
    final advance = ((params['advanceDays'] as num?)?.toInt() ?? 0).clamp(
      0,
      30,
    );
    final useLastDay = params['shortMonthLastDay'] == true;
    final today = DateTime(ctx.now.year, ctx.now.month, ctx.now.day);
    DateTime? dueIn(int year, int month) {
      final first = DateTime(year, month);
      final lastDay = DateTime(first.year, first.month + 1, 0).day;
      if (day > lastDay && !useLastDay) return null;
      return DateTime(first.year, first.month, day.clamp(1, lastDay));
    }

    // A 30-day lead time can reach two calendar months ahead (e.g. Jan 30
    // to Mar 1 in a non-leap year). Keep every matching occurrence, since
    // today's due date and next month's advance date can coincide.
    final results = <AlertResult>[];
    for (final due in [
      dueIn(today.year, today.month),
      dueIn(today.year, today.month + 1),
      dueIn(today.year, today.month + 2),
    ]) {
      if (due == null) continue;
      final daysUntil = DateTime.utc(
        due.year,
        due.month,
        due.day,
      ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
      if (daysUntil != 0 && (advance == 0 || daysUntil != advance)) continue;
      final dateKey =
          '${due.year.toString().padLeft(4, '0')}-'
          '${due.month.toString().padLeft(2, '0')}-'
          '${due.day.toString().padLeft(2, '0')}';
      // A rule without advance reminders keeps its original message and
      // dedup behavior, including compatibility with existing event records.
      final prefix = advance > 0 ? '到期 $dateKey · ' : '';
      results.add(
        AlertResult(
          ruleId: rule.id,
          level: AlertLevel.info,
          title: '现金流提醒',
          dedupPrefix: advance > 0 ? prefix : null,
          message: daysUntil == 0
              ? '$prefix今天是 $label 日（每月 $day 号），请留意资金安排'
              : '$prefix$label 将于 ${due.month} 月 ${due.day} 日到期（提前 $daysUntil 天），请留意资金安排',
        ),
      );
    }
    return results;
  }
}

/// Registry of all evaluators.
final Map<AlertRuleType, RuleEvaluator> ruleEvaluators = {
  AlertRuleType.concentration: const ConcentrationEvaluator(),
  AlertRuleType.assetRatio: const AssetRatioEvaluator(),
  AlertRuleType.drawdown: const DrawdownEvaluator(),
  AlertRuleType.cashflow: const CashflowEvaluator(),
};

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
String _money(double v) => '¥${v.toStringAsFixed(2)}';
