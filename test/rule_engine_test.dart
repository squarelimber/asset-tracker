import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/domain/rule_engine.dart';

AlertRuleRow _rule({
  required int id,
  required AlertRuleType type,
  Map<String, dynamic>? params,
}) {
  return AlertRuleRow(
    id: id,
    type: type.storageName,
    name: type.label,
    params: jsonEncode(params ?? {}),
    enabled: true,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

HoldingRow _holding({
  required int id,
  required String type,
  String? symbol,
  double quantity = 1,
  double price = 100,
  double cost = 90,
}) {
  return HoldingRow(
    id: id,
    accountId: 1,
    name: 'h$id',
    assetType: type,
    marketSource: 'manual',
    symbol: symbol,
    quantity: quantity,
    costPrice: cost,
    latestPrice: price,
    currency: 'CNY',
    note: null,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

RuleContext _ctx({
  required List<HoldingRow> holdings,
  Map<String, double> prev = const {},
  DateTime? now,
}) {
  final summary = const PortfolioCalculator().compute(
    holdings,
    prevPriceBySymbol: prev,
  );
  return RuleContext(summary: summary, holdings: holdings, now: now ?? DateTime(2026, 8, 8));
}

void main() {
  group('ConcentrationEvaluator', () {
    test('flags holding above threshold', () {
      final holdings = [
        _holding(id: 1, type: 'stock', price: 800, cost: 100),
        _holding(id: 2, type: 'cash', quantity: 200, price: 1, cost: 200),
      ];
      final results = const ConcentrationEvaluator()
          .evaluate(_rule(id: 1, type: AlertRuleType.concentration), _ctx(holdings: holdings));
      expect(results, hasLength(1));
      expect(results.single.message, contains('h1'));
    });

    test('does not flag holdings below threshold', () {
      // Four equal holdings -> 25% each, below the 30% default.
      final holdings = [
        _holding(id: 1, type: 'stock', price: 250, cost: 200),
        _holding(id: 2, type: 'cash', quantity: 250, price: 1, cost: 250),
        _holding(id: 3, type: 'mutual_fund', price: 250, cost: 200),
        _holding(id: 4, type: 'etf', price: 250, cost: 200),
      ];
      final results = const ConcentrationEvaluator()
          .evaluate(_rule(id: 1, type: AlertRuleType.concentration), _ctx(holdings: holdings));
      expect(results, isEmpty);
    });

    test('liabilities are excluded from the base and never flagged', () {
      final holdings = [
        _holding(id: 1, type: 'liability', price: 990, cost: 990),
        _holding(id: 2, type: 'cash', quantity: 10, price: 1, cost: 10),
      ];
      final results = const ConcentrationEvaluator()
          .evaluate(_rule(id: 1, type: AlertRuleType.concentration), _ctx(holdings: holdings));
      // Total assets = 10, cash is 100% -> alert, but never about the liability.
      expect(results, hasLength(1));
      expect(results.single.message, contains('h2'));
      expect(results.single.message, isNot(contains('h1')));
    });

    test('respects custom threshold param', () {
      final holdings = [
        _holding(id: 1, type: 'stock', price: 600, cost: 100),
        _holding(id: 2, type: 'cash', quantity: 400, price: 1, cost: 400),
      ];
      final results = const ConcentrationEvaluator().evaluate(
        _rule(id: 1, type: AlertRuleType.concentration, params: {'threshold': 0.7}),
        _ctx(holdings: holdings),
      );
      expect(results, isEmpty);
    });
  });

  group('AssetRatioEvaluator', () {
    test('flags equity below target range', () {
      final holdings = [
        _holding(id: 1, type: 'stock', price: 200, cost: 200),
        _holding(id: 2, type: 'cash', quantity: 800, price: 1, cost: 800),
      ];
      final results = const AssetRatioEvaluator().evaluate(
        _rule(id: 1, type: AlertRuleType.assetRatio, params: {'target': 0.6, 'tolerance': 0.1}),
        _ctx(holdings: holdings),
      );
      expect(results, hasLength(1));
      expect(results.single.message, contains('偏低'));
    });

    test('passes within range', () {
      final holdings = [
        _holding(id: 1, type: 'stock', price: 600, cost: 600),
        _holding(id: 2, type: 'cash', quantity: 400, price: 1, cost: 400),
      ];
      final results = const AssetRatioEvaluator().evaluate(
        _rule(id: 1, type: AlertRuleType.assetRatio, params: {'target': 0.6, 'tolerance': 0.1}),
        _ctx(holdings: holdings),
      );
      expect(results, isEmpty);
    });

    test('flags equity above range as 偏高', () {
      final holdings = [
        _holding(id: 1, type: 'mutual_fund', price: 900, cost: 900),
        _holding(id: 2, type: 'cash', quantity: 100, price: 1, cost: 100),
      ];
      final results = const AssetRatioEvaluator().evaluate(
        _rule(id: 1, type: AlertRuleType.assetRatio, params: {'target': 0.6, 'tolerance': 0.1}),
        _ctx(holdings: holdings),
      );
      expect(results.single.message, contains('偏高'));
    });
  });

  group('DrawdownEvaluator', () {
    test('flags daily drop above threshold', () {
      final holdings = [
        _holding(id: 1, type: 'stock', symbol: 'sh600519', quantity: 1, price: 95, cost: 100),
      ];
      final results = const DrawdownEvaluator().evaluate(
        _rule(id: 1, type: AlertRuleType.drawdown, params: {'threshold': 0.03}),
        _ctx(holdings: holdings, prev: {'sh600519': 100}),
      );
      expect(results, hasLength(1));
      expect(results.single.level, AlertLevel.danger);
    });

    test('no alert on gain', () {
      final holdings = [
        _holding(id: 1, type: 'stock', symbol: 'sh600519', quantity: 1, price: 105, cost: 100),
      ];
      final results = const DrawdownEvaluator().evaluate(
        _rule(id: 1, type: AlertRuleType.drawdown),
        _ctx(holdings: holdings, prev: {'sh600519': 100}),
      );
      expect(results, isEmpty);
    });

    test('no alert when previous price unknown', () {
      final holdings = [
        _holding(id: 1, type: 'stock', price: 90, cost: 100),
      ];
      final results = const DrawdownEvaluator().evaluate(
        _rule(id: 1, type: AlertRuleType.drawdown),
        _ctx(holdings: holdings),
      );
      expect(results, isEmpty);
    });
  });

  group('CashflowEvaluator', () {
    test('alerts on the configured day', () {
      final results = const CashflowEvaluator().evaluate(
        _rule(id: 1, type: AlertRuleType.cashflow, params: {'dayOfMonth': 8, 'label': '鎴胯捶杩樻'}),
        _ctx(holdings: [], now: DateTime(2026, 8, 8)),
      );
      expect(results, hasLength(1));
      expect(results.single.message, contains('鎴胯捶杩樻'));
    });

    test('silent on other days', () {
      final results = const CashflowEvaluator().evaluate(
        _rule(id: 1, type: AlertRuleType.cashflow, params: {'dayOfMonth': 20, 'label': '瀹氭姇'}),
        _ctx(holdings: [], now: DateTime(2026, 8, 8)),
      );
      expect(results, isEmpty);
    });
  });
}
