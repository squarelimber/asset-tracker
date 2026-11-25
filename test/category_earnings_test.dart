import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/category_earnings.dart';
import 'package:asset_tracker/domain/earnings_breakdown.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

DayHoldingValue _value(
  int id,
  double value,
  double cost, {
  AssetType type = AssetType.etf,
  String? name,
  double realized = 0,
}) => DayHoldingValue(
  holdingId: id,
  name: name ?? '产品$id',
  type: type,
  value: value,
  cost: cost,
  liability: type == AssetType.liability,
  realizedProfit: realized,
);

SnapshotRow _snapshot(String date, List<DayHoldingValue> values) {
  final assets = values.where((h) => !h.liability);
  final liabilities = values.where((h) => h.liability);
  return SnapshotRow(
    date: date,
    currency: 'CNY',
    totalValue:
        assets.fold(0.0, (sum, h) => sum + h.value) -
        liabilities.fold(0.0, (sum, h) => sum + h.value),
    totalCost: assets.fold(0.0, (sum, h) => sum + h.cost),
    liabilities: liabilities.fold(0.0, (sum, h) => sum + h.value),
    realizedProfit: assets.fold<double>(
      0.0,
      (sum, h) => sum + h.realizedProfit,
    ),
    holdingValues: encodeHoldingValues(values),
    createdAt: DateTime(2026, 2),
  );
}

HoldingRow _holding(
  int id, {
  AssetType type = AssetType.etf,
  AssetCategory? category,
  bool archived = false,
  double quantity = 1,
}) => HoldingRow(
  id: id,
  accountId: 1,
  name: '产品$id',
  assetType: type.storageName,
  marketSource: 'manual',
  quantity: quantity,
  costPrice: 100,
  latestPrice: 100,
  currency: 'CNY',
  categoryOverride: category?.storageName,
  archived: archived,
  costRecorded: true,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

CategoryEarningsReport _report(
  List<SnapshotRow> snapshots, {
  List<HoldingRow> holdings = const [],
  List<TransactionRow> transactions = const [],
  String from = '2026-01-02',
  String to = '2026-01-03',
}) => categoryEarningsOf(
  snapshots,
  holdings: holdings,
  transactions: transactions,
  from: from,
  to: to,
);

void main() {
  test('inclusive dates use the prior baseline and omit later earnings', () {
    final report = _report([
      _snapshot('2026-01-04', [_value(1, 999, 100)]),
      _snapshot('2026-01-02', [_value(1, 110, 100)]),
      _snapshot('2026-01-01', [_value(1, 100, 100)]),
      _snapshot('2026-01-03', [_value(1, 115, 100)]),
    ]);
    expect(report.verified, isTrue);
    expect(report.days, 2);
    expect(report.totalProfit, 15);
    expect(report.totalRate, 0.15);
    expect(report.categories.single.profit, 15);
    expect(report.categories.single.rate, 0.15);
  });

  test('principal deposits and withdrawals do not become earnings', () {
    final report = _report([
      _snapshot('2026-01-01', [_value(1, 100, 100)]),
      _snapshot('2026-01-02', [_value(1, 210, 200)]),
      _snapshot('2026-01-03', [_value(1, 165, 150)]),
    ]);
    expect(report.verified, isTrue);
    expect(report.totalProfit, 15);
    expect(report.categories.single.rate, 0.15);
  });

  test(
    'category rate uses opening assets instead of averaging product rates',
    () {
      final report = _report([
        _snapshot('2026-01-01', [_value(1, 100, 100), _value(2, 900, 900)]),
        _snapshot('2026-01-02', [_value(1, 110, 100), _value(2, 900, 900)]),
      ]);
      final category = report.categories.single;
      expect(category.rate, 0.01);
      expect(category.products.map((product) => product.rate), [0.1, 0.0]);
      expect(report.totalRate, 0.01);
    },
  );

  test(
    'current manual categories apply to historical and archived holdings',
    () {
      final report = _report(
        [
          _snapshot('2026-01-01', [_value(1, 100, 100)]),
          _snapshot('2026-01-02', [_value(1, 110, 100)]),
        ],
        holdings: [_holding(1, category: AssetCategory.gold, archived: true)],
      );
      expect(report.categories.single.category, AssetCategory.gold);
      expect(report.categories.single.profit, 10);
    },
  );

  test('deleted holdings fall back to the recorded type category', () {
    final report = _report([
      _snapshot('2026-01-01', [_value(1, 100, 100, type: AssetType.bond)]),
      _snapshot('2026-01-02', [_value(1, 105, 100, type: AssetType.bond)]),
    ]);
    expect(report.categories.single.category, AssetCategory.bond);
    expect(report.categories.single.profit, 5);
  });

  test(
    'same names merge within a category while remaining split across categories',
    () {
      final report = _report(
        [
          _snapshot('2026-01-01', [
            _value(1, 100, 100, name: '同名基金'),
            _value(2, 200, 200, name: '同名基金'),
            _value(3, 300, 300, name: '同名基金'),
          ]),
          _snapshot('2026-01-02', [
            _value(1, 110, 100, name: '同名基金'),
            _value(2, 220, 200, name: '同名基金'),
            _value(3, 330, 300, name: '同名基金'),
          ]),
        ],
        holdings: [
          _holding(1, category: AssetCategory.gold),
          _holding(2, category: AssetCategory.gold),
          _holding(3),
        ],
      );
      expect(report.categories, hasLength(2));
      final gold = report.categories.singleWhere(
        (c) => c.category == AssetCategory.gold,
      );
      final equity = report.categories.singleWhere(
        (c) => c.category == AssetCategory.equity,
      );
      expect(gold.products.single.holdingIds, [1, 2]);
      expect(gold.products.single.profit, 30);
      expect(gold.products.single.rate, 0.1);
      expect(equity.products.single.holdingIds, [3]);
      expect(report.totalProfit, 60);
    },
  );

  test(
    'internal sale keeps carried gains in their original asset category',
    () {
      final report = _report(
        [
          _snapshot('2026-01-01', [
            _value(1, 110, 100),
            _value(2, 100, 100, type: AssetType.cash),
          ]),
          _snapshot('2026-01-02', [
            _value(1, 0, 0),
            _value(2, 220, 200, type: AssetType.cash),
          ]),
        ],
        transactions: [
          TransactionRow(
            id: 1,
            accountId: 1,
            holdingId: 1,
            cashTargetId: 2,
            type: 'sell',
            amount: 120,
            currency: 'CNY',
            occurredAt: DateTime(2026, 1, 2),
            costMoved: true,
            costMovedAmount: 100,
            internalMove: false,
            updatedAt: DateTime(2026, 1, 2),
          ),
        ],
      );
      expect(report.verified, isTrue);
      expect(report.totalProfit, 10);
      expect(
        report.categories
            .singleWhere((c) => c.category == AssetCategory.equity)
            .profit,
        10,
      );
      expect(
        report.categories
            .singleWhere((c) => c.category == AssetCategory.cash)
            .profit,
        0,
      );
    },
  );

  test('external liquidation retains realized gains and archived products', () {
    final report = _report(
      [
        _snapshot('2026-01-01', [_value(1, 110, 100)]),
        _snapshot('2026-01-02', [_value(1, 0, 0, realized: 15)]),
        _snapshot('2026-01-03', [_value(1, 0, 0, realized: 15)]),
      ],
      holdings: [_holding(1, quantity: 0, archived: true)],
    );
    expect(report.verified, isTrue);
    expect(report.totalProfit, 5);
    expect(report.categories.single.products.single.profit, 5);
    expect(report.categories.single.products.single.closed, isTrue);
    expect(report.categories.single.rate, closeTo(5 / 110, 1e-12));
  });

  test('liability changes remain outside the asset return', () {
    final report = _report([
      _snapshot('2026-01-01', [
        _value(1, 100, 100),
        _value(2, 50, 50, type: AssetType.liability),
      ]),
      _snapshot('2026-01-02', [
        _value(1, 110, 100),
        _value(2, 20, 20, type: AssetType.liability),
      ]),
    ]);
    expect(report.totalProfit, 10);
    expect(report.categories.single.products.single.holdingIds, [1]);
    expect(report.totalRate, 0.1);
  });

  test('a new position without positive opening assets has no return rate', () {
    final report = _report([
      _snapshot('2026-01-01', []),
      _snapshot('2026-01-02', [_value(1, 105, 100)]),
    ]);
    expect(report.totalProfit, 5);
    expect(report.totalRate, isNull);
    expect(report.categories.single.rate, isNull);
    expect(report.categories.single.products.single.rate, isNull);
  });

  test('first recorded observation establishes a zero-profit baseline', () {
    final report = _report([
      _snapshot('2026-01-02', [_value(1, 110, 100)]),
    ]);
    expect(report.totalProfit, 0);
    expect(report.totalRate, 0);
    expect(report.categories.single.profit, 0);
    expect(report.verified, isTrue);
  });

  test('a gap fully inside the range has an exact aggregate', () {
    final report = _report([
      _snapshot('2026-01-01', [_value(1, 100, 100)]),
      _snapshot('2026-01-05', [_value(1, 120, 100)]),
    ], to: '2026-01-05');
    expect(report.totalProfit, 20);
    expect(report.days, 1);
    expect(report.verified, isTrue);
  });

  test('gaps crossing either boundary suppress all category results', () {
    for (final snapshots in [
      [
        _snapshot('2025-12-31', [_value(1, 100, 100)]),
        _snapshot('2026-01-02', [_value(1, 110, 100)]),
      ],
      [
        _snapshot('2026-01-01', [_value(1, 100, 100)]),
        _snapshot('2026-01-02', [_value(1, 110, 100)]),
        _snapshot('2026-01-05', [_value(1, 120, 100)]),
      ],
    ]) {
      final report = _report(snapshots);
      expect(report.verified, isFalse);
      expect(report.categories, isEmpty);
      expect(report.totalRate, isNull);
      expect(report.issues.single.canRebuild, isTrue);
    }
  });

  test('a crossing gap is reported even when the range has no snapshot', () {
    final report = _report([
      _snapshot('2026-01-01', [_value(1, 100, 100)]),
      _snapshot('2026-01-05', [_value(1, 120, 100)]),
    ]);
    expect(report.isEmpty, isTrue);
    expect(report.verified, isFalse);
  });

  test('missing baseline or period details suppress all category results', () {
    for (final missing in [0, 1]) {
      final snapshots = [
        _snapshot('2026-01-01', [_value(1, 100, 100)]),
        _snapshot('2026-01-02', [_value(1, 110, 100)]),
      ];
      snapshots[missing] = snapshots[missing].copyWith(
        holdingValues: const Value(null),
      );
      final report = _report(snapshots);
      expect(report.verified, isFalse);
      expect(report.categories, isEmpty);
      expect(report.totalRate, isNull);
      expect(report.issues.first.canRebuild, isTrue);
    }
  });

  test('incomplete internal attribution is surfaced with its transaction', () {
    final report = _report(
      [
        _snapshot('2026-01-01', [
          _value(1, 110, 100),
          _value(2, 100, 100, type: AssetType.cash),
        ]),
        _snapshot('2026-01-02', [
          _value(1, 0, 0),
          _value(2, 220, 200, type: AssetType.cash),
        ]),
      ],
      transactions: [
        TransactionRow(
          id: 9,
          accountId: 1,
          holdingId: 1,
          cashTargetId: 2,
          type: 'sell',
          amount: 120,
          currency: 'CNY',
          occurredAt: DateTime(2026, 1, 2),
          costMoved: false,
          internalMove: false,
          updatedAt: DateTime(2026, 1, 2),
        ),
      ],
    );
    expect(report.verified, isFalse);
    expect(report.categories, isEmpty);
    expect(report.issues.single.transactionId, 9);
  });

  test('empty and non-CNY snapshots do not fabricate categories', () {
    for (final snapshots in [
      <SnapshotRow>[],
      [
        _snapshot('2026-01-02', [
          _value(1, 100, 100),
        ]).copyWith(currency: 'USD'),
      ],
    ]) {
      final report = _report(snapshots);
      expect(report.isEmpty, isTrue);
      expect(report.verified, isTrue);
      expect(report.totalProfit, 0);
      expect(report.totalRate, isNull);
      expect(report.categories, isEmpty);
    }
  });

  test('extracting holding series preserves existing product merging', () {
    final snapshots = [
      _snapshot('2026-01-01', [
        _value(1, 100, 100, name: '同名'),
        _value(2, 200, 200, name: '同名'),
      ]),
      _snapshot('2026-01-02', [
        _value(1, 110, 100, name: '同名'),
        _value(2, 220, 200, name: '同名'),
      ]),
    ];
    expect(holdingSeriesFromSnapshots(snapshots), hasLength(2));
    final products = productsFromSnapshots(snapshots);
    expect(products, hasLength(1));
    expect(
      const ProductEarningsCalculator()
          .monthOf(products.single, 2026, 1)
          .profit,
      30,
    );
  });
}
