import 'dart:convert';

import '../core/enums.dart';
import '../data/database.dart';
import 'portfolio_calculator.dart';

enum AlertLevel { info, warning, danger }

class AlertResult {
  const AlertResult({
    required this.ruleId,
    required this.level,
    required this.title,
    required this.message,
  });

  final int ruleId;
  final AlertLevel level;
  final String title;
  final String message;
}

/// Everything a rule needs to evaluate.
class RuleContext {
  RuleContext({
    required this.summary,
    required this.holdings,
    this.priceCache = const {},
    DateTime? now,
  }) : now = now ?? DateTime.now();

  final PortfolioSummary summary;
  final List<HoldingRow> holdings;

  /// symbol -> cached price (for per-holding daily change).
  final Map<String, PriceCacheRow> priceCache;
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
      final marketValue = h.quantity * h.latestPrice;
      final ratio = marketValue / total;
      if (ratio > threshold) {
        results.add(AlertResult(
          ruleId: rule.id,
          level: ratio > threshold * 1.2 ? AlertLevel.danger : AlertLevel.warning,
          title: '集中度风险',
          message: '「${h.name}」市值 ${_money(marketValue)} 占总资产 ${_pct(ratio)}，'
              '超过阈值 ${_pct(threshold)}',
        ));
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

  static const _equityTypes = {AssetType.stock, AssetType.etf, AssetType.mutualFund};

  @override
  AlertRuleType get type => AlertRuleType.assetRatio;

  @override
  List<AlertResult> evaluate(AlertRuleRow rule, RuleContext ctx) {
    final params = paramsOf(rule);
    final target = (params['target'] as num?)?.toDouble() ?? 0.6;
    final tolerance = (params['tolerance'] as num?)?.toDouble() ?? 0.15;
    final total = ctx.summary.totalAssets;
    if (total <= 0) return const [];

    var equity = 0.0;
    for (final h in ctx.holdings) {
      final type = AssetType.fromStorage(h.assetType);
      if (_equityTypes.contains(type)) {
        equity += h.quantity * h.latestPrice;
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
          message: '权益类资产占比 ${_pct(ratio)}，目标 ${_pct(target)}'
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
    final day = (params['dayOfMonth'] as num?)?.toInt() ?? 1;
    final label = params['label']?.toString() ?? '现金流事项';
    if (ctx.now.day == day) {
      return [
        AlertResult(
          ruleId: rule.id,
          level: AlertLevel.info,
          title: '现金流提醒',
          message: '今天是 $label 日（每月 $day 号），请留意资金安排',
        ),
      ];
    }
    return const [];
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
