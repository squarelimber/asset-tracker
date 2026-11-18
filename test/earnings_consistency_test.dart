import 'dart:async';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/daily_earnings.dart';
import 'package:asset_tracker/domain/earnings_breakdown.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:asset_tracker/services/backup_service.dart';
import 'package:asset_tracker/sync/sync_format.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DayHoldingValue _holding(
  int id,
  double value,
  double cost, {
  bool debt = false,
  AssetType type = AssetType.etf,
}) => DayHoldingValue(
  holdingId: id,
  name: '产品$id',
  type: debt ? AssetType.liability : type,
  value: value,
  cost: cost,
  liability: debt,
);

SnapshotRow _snapshot(String date, List<DayHoldingValue> values) {
  final assets = values
      .where((h) => !h.liability)
      .fold(0.0, (v, h) => v + h.value);
  final debt = values
      .where((h) => h.liability)
      .fold(0.0, (v, h) => v + h.value);
  final cost = values
      .where((h) => !h.liability)
      .fold(0.0, (v, h) => v + h.cost);
  return SnapshotRow(
    date: date,
    currency: 'CNY',
    totalValue: assets - debt,
    totalCost: cost,
    liabilities: debt,
    holdingValues: encodeHoldingValues(values),
    createdAt: DateTime(2026),
  );
}

void main() {
  test('internal gain attribution is balanced and conservative', () {
    TransactionRow row({
      required int id,
      required String type,
      int? holding,
      int? source,
      int? target,
      double? moved = 80,
      bool internal = false,
      String currency = 'CNY',
      DateTime? when,
    }) => TransactionRow(
      id: id,
      accountId: 1,
      holdingId: holding,
      cashSourceId: source,
      cashTargetId: target,
      type: type,
      amount: 100,
      currency: currency,
      occurredAt: when ?? DateTime(2026, 11, 16),
      costMoved: true,
      costMovedAmount: moved,
      internalMove: internal,
      updatedAt: DateTime(2026),
    );
    Map<int, double> adjusted(List<TransactionRow> rows, [Set<int>? ids]) =>
        internalTransferProfitAdjustments(
          rows,
          '2026-11-15',
          '2026-11-17',
          ids ?? {1, 2},
        );
    expect(adjusted([row(id: 1, type: 'sell', holding: 1, target: 2)]), {
      1: 20,
      2: -20,
    });
    expect(adjusted([row(id: 1, type: 'transfer_out', source: 1, target: 2)]), {
      1: 20,
      2: -20,
    });
    expect(
      adjusted([
        row(id: 1, type: 'sell', holding: 1, internal: true),
        row(id: 2, type: 'buy', holding: 2, internal: true),
      ]),
      {1: 20, 2: -20},
    );
    expect(
      adjusted([row(id: 1, type: 'buy', holding: 2, source: 1, moved: null)]),
      isEmpty,
    );
    expect(
      adjusted([
        row(id: 1, type: 'buy', holding: 2, source: 1, currency: 'USD'),
      ]),
      isEmpty,
    );
    expect(
      adjusted([row(id: 1, type: 'buy', holding: 2, source: 1)], {2}),
      isEmpty,
    );
    expect(
      adjusted([row(id: 1, type: 'dividend', holding: 1, target: 2)]),
      isEmpty,
    );
    expect(
      adjusted([
        row(
          id: 1,
          type: 'buy',
          holding: 2,
          source: 1,
          when: DateTime(2026, 11, 15),
        ),
      ]),
      isEmpty,
    );
    expect(
      adjusted([
        row(id: 1, type: 'sell', holding: 1, internal: true),
        row(id: 2, type: 'buy', holding: 2, internal: true),
        row(id: 3, type: 'buy', holding: 2, internal: true),
      ]),
      isEmpty,
    );
  });

  test('funded ETF purchase attributes only the new price loss to the ETF', () {
    final snapshots = [
      _snapshot('2026-11-15', [
        _holding(1, 10000, 8148),
        _holding(2, 3000, 3500),
      ]),
      _snapshot('2026-11-17', [
        _holding(1, 5397.7, 4398),
        _holding(2, 7595.4, 7250),
      ]),
    ];
    final buy = TransactionRow(
      id: 1,
      accountId: 1,
      holdingId: 2,
      cashSourceId: 1,
      type: 'buy',
      quantity: 2300,
      price: 2.001,
      amount: 4602.3,
      currency: 'CNY',
      occurredAt: DateTime(2026, 11, 16),
      costMoved: true,
      costMovedAmount: 3750,
      internalMove: false,
      updatedAt: DateTime(2026),
    );
    final detail = earningsBreakdownOf(
      snapshots,
      '2026-11-17',
      transactions: [buy],
    );
    expect(
      detail.rows.singleWhere((r) => r.holdingId == 1).profit,
      closeTo(0, 1e-8),
    );
    expect(
      detail.rows.singleWhere((r) => r.holdingId == 2).profit,
      closeTo(-6.9, 1e-8),
    );
    expect(detail.detailTotal, closeTo(-6.9, 1e-8));
    expect(detail.verified, isTrue);
    final stale = buy.copyWith(updatedAt: DateTime(2026, 11, 17));
    expect(
      earningsBreakdownOf(
        snapshots,
        '2026-11-17',
        transactions: [stale],
      ).verified,
      isFalse,
    );
    expect(
      () => productsFromSnapshots(snapshots, transactions: [stale]),
      throwsStateError,
    );
    final products = productsFromSnapshots(snapshots, transactions: [buy]);
    const calc = ProductEarningsCalculator();
    expect(
      calc
          .monthOf(products.singleWhere((p) => p.name == '产品1'), 2026, 11)
          .profit,
      closeTo(0, 1e-8),
    );
    expect(
      calc
          .monthOf(products.singleWhere((p) => p.name == '产品2'), 2026, 11)
          .profit,
      closeTo(-6.9, 1e-8),
    );
  });

  test(
    'internal move with no observable position on one side is not applied',
    () {
      final snapshots = [
        _snapshot('2026-11-15', [_holding(1, 600, 500), _holding(2, 0, 0)]),
        _snapshot('2026-11-17', [_holding(1, 480, 400), _holding(2, 0, 0)]),
      ];
      final transfer = TransactionRow(
        id: 1,
        accountId: 1,
        holdingId: 2,
        cashSourceId: 1,
        type: 'buy',
        amount: 120,
        currency: 'CNY',
        occurredAt: DateTime(2026, 11, 16),
        costMoved: true,
        costMovedAmount: 100,
        internalMove: false,
        updatedAt: DateTime(2026),
      );
      final detail = earningsBreakdownOf(
        snapshots,
        '2026-11-17',
        transactions: [transfer],
      );
      expect(detail.rows.single.profit, -20);
      expect(detail.verified, isFalse);
      expect(
        () => productsFromSnapshots(snapshots, transactions: [transfer]),
        throwsStateError,
      );
    },
  );

  test('incomplete internal movements do not claim reliable attribution', () {
    final snapshots = [
      _snapshot('2026-11-15', [_holding(1, 600, 500), _holding(2, 200, 200)]),
      _snapshot('2026-11-17', [_holding(1, 480, 400), _holding(2, 320, 300)]),
    ];
    TransactionRow movement({
      required int id,
      required String type,
      int? holding,
      int? source,
      double? moved = 100,
      bool internal = false,
      String currency = 'CNY',
    }) => TransactionRow(
      id: id,
      accountId: 1,
      holdingId: holding,
      cashSourceId: source,
      type: type,
      amount: 120,
      currency: currency,
      occurredAt: DateTime(2026, 11, 16),
      costMoved: true,
      costMovedAmount: moved,
      internalMove: internal,
      updatedAt: DateTime(2026),
    );

    final scenarios = <String, List<TransactionRow>>{
      'missing transferred cost': [
        movement(id: 1, type: 'buy', holding: 2, source: 1, moved: null),
      ],
      'foreign currency without historical exchange rate': [
        movement(id: 1, type: 'buy', holding: 2, source: 1, currency: 'USD'),
      ],
      'unpaired redemption leg': [
        movement(id: 1, type: 'sell', holding: 1, internal: true),
      ],
      'unpaired purchase leg': [
        movement(id: 1, type: 'buy', holding: 2, internal: true),
      ],
      'ambiguous paired purchase legs': [
        movement(id: 1, type: 'sell', holding: 1, internal: true),
        movement(id: 2, type: 'buy', holding: 2, internal: true),
        movement(id: 3, type: 'buy', holding: 2, internal: true),
      ],
    };
    for (final scenario in scenarios.entries) {
      final detail = earningsBreakdownOf(
        snapshots,
        '2026-11-17',
        transactions: scenario.value,
      );
      expect(detail.verified, isFalse, reason: scenario.key);
      expect(detail.issue, contains('2026-11-16'), reason: scenario.key);
      expect(
        () => productsFromSnapshots(snapshots, transactions: scenario.value),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'dated issue',
            detail.issue,
          ),
        ),
        reason: scenario.key,
      );
    }
  });

  test(
    'credit card repayment does not block daily or monthly asset attribution',
    () {
      final snapshots = [
        _snapshot('2026-11-15', [
          _holding(1, 600, 500, type: AssetType.liquidWealth),
          _holding(2, 120, 0, debt: true),
        ]),
        _snapshot('2026-11-17', [
          _holding(1, 480, 400, type: AssetType.liquidWealth),
        ]),
      ];
      final repayment = TransactionRow(
        id: 1,
        accountId: 1,
        cashSourceId: 1,
        cashTargetId: 2,
        type: 'transfer_in',
        amount: 120,
        currency: 'CNY',
        occurredAt: DateTime(2026, 11, 16),
        costMoved: true,
        costMovedAmount: 100,
        internalMove: false,
        updatedAt: DateTime(2026),
      );
      final detail = earningsBreakdownOf(
        snapshots,
        '2026-11-17',
        transactions: [repayment],
      );
      expect(detail.verified, isTrue);
      expect(detail.rows.single.holdingId, 1);
      final products = productsFromSnapshots(
        snapshots,
        transactions: [repayment],
      );
      expect(
        const ProductEarningsCalculator()
            .monthOf(products.single, 2026, 11)
            .profit,
        detail.detailTotal,
      );
    },
  );

  test('daily detail is the day delta, not cumulative profit', () {
    final snapshots = [
      _snapshot('2026-11-04', [_holding(1, 1100, 1000)]),
      _snapshot('2026-11-05', [_holding(1, 1125, 1000)]),
    ];
    final detail = earningsBreakdownOf(snapshots, '2026-11-05');
    expect(detail.verified, isTrue);
    expect(detail.rows.single.profit, 25);
    expect(
      detail.profit,
      todayEarningOf(snapshots, now: DateTime(2026, 11, 5))!.profit,
    );
  });

  test(
    'snapshot gaps, new holdings and disappearing holdings still reconcile',
    () {
      final snapshots = [
        _snapshot('2026-10-30', [
          _holding(1, 1100, 1000),
          _holding(9, 50, 0, debt: true),
        ]),
        _snapshot('2026-11-02', [
          _holding(2, 2250, 2000),
          _holding(9, 500, 0, debt: true),
        ]),
      ];
      final detail = earningsBreakdownOf(snapshots, '2026-11-02');
      expect(detail.baselineDate, '2026-10-30');
      expect(detail.rows.map((r) => r.holdingId).toSet(), {1, 2});
      expect(detail.rows.firstWhere((r) => r.holdingId == 1).profit, -100);
      expect(detail.rows.firstWhere((r) => r.holdingId == 2).profit, 250);
      expect(detail.detailTotal, 150);
      expect(detail.profit, 150);
      expect(detail.verified, isTrue);
    },
  );

  test('first snapshot has zero daily return rather than all-time gain', () {
    final detail = earningsBreakdownOf([
      _snapshot('2026-11-05', [_holding(1, 1500, 1000)]),
    ], '2026-11-05');
    expect(detail.profit, 0);
    expect(detail.rows.single.profit, 0);
    expect(detail.verified, isTrue);
  });

  test('daily detail stops listing a closed ETF after its closing day', () {
    final snapshots = [
      _snapshot('2026-11-11', [_holding(1, 1100, 1000), _holding(2, 900, 900)]),
      _snapshot('2026-11-12', [_holding(1, 0, 0), _holding(2, 2040, 1900)]),
      _snapshot('2026-11-13', [_holding(1, 0, 0), _holding(2, 2040, 1900)]),
      _snapshot('2026-11-14', [_holding(1, 0, 0), _holding(2, 2050, 1900)]),
    ];
    final closingDay = earningsBreakdownOf(snapshots, '2026-11-12');
    expect(
      closingDay.rows.singleWhere((row) => row.holdingId == 1).profit,
      -100,
    );
    expect(closingDay.detailTotal, 40);
    expect(closingDay.verified, isTrue);

    for (final (date, profit) in [('2026-11-13', 0), ('2026-11-14', 10)]) {
      final detail = earningsBreakdownOf(snapshots, date);
      expect(detail.rows.single.holdingId, 2);
      expect(detail.rows.single.profit, profit);
      expect(detail.detailTotal, detail.profit);
      expect(detail.verified, isTrue);
    }
  });

  test('transfers move value and cost together without creating earnings', () {
    final detail = earningsBreakdownOf([
      _snapshot('2026-11-04', [_holding(1, 1000, 900), _holding(2, 0, 0)]),
      _snapshot('2026-11-05', [_holding(1, 400, 360), _holding(2, 600, 540)]),
    ], '2026-11-05');
    expect(detail.detailTotal, 0);
    expect(detail.profit, 0);
    expect(detail.verified, isTrue);
  });

  test('legacy or tampered snapshots never claim a verified explanation', () {
    final current = _snapshot('2026-11-05', [_holding(1, 1500, 1000)]);
    final legacy = current.copyWith(holdingValues: const Value(null));
    expect(earningsBreakdownOf([legacy], legacy.date).verified, isFalse);
    expect(earningsBreakdownOf([legacy], legacy.date).profit, 0);
    expect(snapshotHoldingValues(current.copyWith(totalValue: 999)), isNull);
    expect(earningsBreakdownOf([current], '2026-11-06').profit, isNull);
  });

  test('product month and year totals sum to the same calendar series', () {
    final snapshots = [
      _snapshot('2025-12-31', [_holding(1, 1100, 1000)]),
      _snapshot('2026-01-01', [
        _holding(1, 1120, 1000),
        _holding(2, 2300, 2000),
      ]),
      _snapshot('2026-02-01', [_holding(2, 2350, 2000)]),
    ];
    final products = productsFromSnapshots(snapshots);
    const calc = ProductEarningsCalculator();
    final daily = const DailyEarningsCalculator().compute(snapshots);
    for (final month in [1, 2]) {
      final total = products.fold(
        0.0,
        (v, p) => v + calc.monthOf(p, 2026, month).profit,
      );
      expect(
        total,
        const DailyEarningsCalculator().monthOf(daily, 2026, month).total,
      );
    }
    expect(
      products.fold(0.0, (v, p) => v + calc.yearlyProfit(calc.yearOf(p, 2026))),
      const DailyEarningsCalculator().yearOf(daily, 2026).total,
    );
  });

  test('product calendar keeps closing month and skips inactive months', () {
    final snapshots = [
      _snapshot('2026-01-31', [_holding(1, 0, 0), _holding(2, 900, 900)]),
      _snapshot('2026-02-01', [_holding(1, 0, 0), _holding(2, 900, 900)]),
      _snapshot('2026-02-02', [_holding(1, 1000, 1000), _holding(2, 900, 900)]),
      _snapshot('2026-02-28', [_holding(1, 1120, 1000), _holding(2, 900, 900)]),
      _snapshot('2026-03-01', [_holding(1, 0, 0), _holding(2, 2030, 1900)]),
      _snapshot('2026-03-02', [_holding(1, 0, 0), _holding(2, 2030, 1900)]),
      _snapshot('2026-04-01', [_holding(2, 2030, 1900)]),
    ];
    const calc = ProductEarningsCalculator();
    final products = productsFromSnapshots(snapshots);
    final etf = products.firstWhere((p) => p.name == '产品1');
    expect(etf.closed, isTrue);
    expect(calc.yearOf(etf, 2026).map((m) => m.month), [2, 3]);
    final holdingMonth = calc.monthOf(etf, 2026, 2);
    expect(holdingMonth.dailyProfits, [0, 120]);
    expect(holdingMonth.rate, 0.12);
    expect(holdingMonth.closed, isNull);
    final closingMonth = calc.monthOf(etf, 2026, 3);
    expect(closingMonth.dailyProfits, [-120]);
    expect(closingMonth.closed, isTrue);
    expect(calc.yearlyRate(calc.yearOf(etf, 2026), etf, 2026), 0);
    final marchProfit = products.fold(
      0.0,
      (sum, p) => sum + calc.monthOf(p, 2026, 3).profit,
    );
    expect(marchProfit, 10);
    expect(marchProfit, earningsBreakdownOf(snapshots, '2026-03-01').profit);

    final reopened = productsFromSnapshots([
      ...snapshots,
      _snapshot('2026-05-01', [_holding(1, 520, 500), _holding(2, 2030, 1900)]),
    ]).firstWhere((p) => p.name == '产品1');
    expect(reopened.closed, isFalse);
    expect(calc.yearOf(reopened, 2026).map((m) => m.month), [2, 3, 5]);
    expect(calc.monthOf(reopened, 2026, 5).profit, 20);
  });

  test('product earnings exclude a holding after reclassification as debt', () {
    final snapshots = [
      _snapshot('2026-03-01', [_holding(1, 110, 100)]),
      _snapshot('2026-03-02', [_holding(1, 180, 0, debt: true)]),
      _snapshot('2026-03-03', [_holding(1, 300, 0, debt: true)]),
    ];
    final product = productsFromSnapshots(snapshots).single;
    final month = const ProductEarningsCalculator().monthOf(product, 2026, 3);
    expect(product.closed, isTrue);
    expect(month.dailyProfits, [0, -10]);
    expect(month.profit, earningsBreakdownOf(snapshots, '2026-03-02').profit);
  });

  test(
    'snapshot errors propagate instead of becoming an empty calendar',
    () async {
      final container = ProviderContainer(
        overrides: [
          snapshotsProvider.overrideWith(
            (ref) => Stream.error(StateError('read failed')),
          ),
          transactionsProvider.overrideWith((ref) => Stream.value([])),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(dailyEarningsProvider.future),
        throwsStateError,
      );
    },
  );

  test(
    'new snapshots invalidate daily detail while recorded values stay fixed',
    () async {
      final stream = StreamController<List<SnapshotRow>>();
      final container = ProviderContainer(
        overrides: [
          snapshotsProvider.overrideWith((ref) => stream.stream),
          transactionsProvider.overrideWith((ref) => Stream.value([])),
        ],
      );
      final subscription = container.listen(
        earningsBreakdownProvider(DateTime(2026, 11, 5)),
        (_, _) {},
      );
      addTearDown(() async {
        subscription.close();
        container.dispose();
        await stream.close();
      });
      final before = _snapshot('2026-11-04', [_holding(1, 1100, 1000)]);
      stream.add([
        before,
        _snapshot('2026-11-05', [_holding(1, 1125, 1000)]),
      ]);
      expect(
        (await container.read(
          earningsBreakdownProvider(DateTime(2026, 11, 5)).future,
        )).profit,
        25,
      );
      stream.add([
        before,
        _snapshot('2026-11-05', [_holding(1, 1150, 1000)]),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(
        (await container.read(
          earningsBreakdownProvider(DateTime(2026, 11, 5)).future,
        )).profit,
        50,
      );
    },
  );

  test(
    'backup and sync wire formats preserve recorded valuations; legacy overwrite clears them',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final restored = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      addTearDown(restored.close);
      final dao = AssetDao(db);
      final row = _snapshot('2026-11-05', [_holding(1, 1125, 1000)]);
      await dao.upsertSnapshot(row.toCompanion(true));
      expect(
        const SyncFormatter().snapshotToRow(row)['holdingValues'],
        row.holdingValues,
      );
      final backup = await BackupService(dao).exportJson();
      expect(
        (await BackupService(AssetDao(restored)).importJson(backup)).ok,
        isTrue,
      );
      expect(
        snapshotHoldingValues(
          (await AssetDao(restored).getSnapshots()).single,
        )!.single.value,
        1125,
      );
      await dao.upsertSnapshot(
        SnapshotsCompanion.insert(
          date: row.date,
          totalValue: 1125,
          totalCost: 1000,
        ),
      );
      expect((await dao.getSnapshots()).single.holdingValues, isNull);
    },
  );

  test('v12 migration preserves old aggregates and adds nullable detail', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (sqlite) {
          sqlite.execute(
            'CREATE TABLE snapshots (date TEXT NOT NULL, currency TEXT NOT NULL, total_value REAL NOT NULL, total_cost REAL NOT NULL, liabilities REAL NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (date, currency))',
          );
          sqlite.execute(
            "INSERT INTO snapshots VALUES ('2026-11-05', 'CNY', 1234, 1000, 0, 1)",
          );
          sqlite.execute('PRAGMA user_version = 12');
        },
      ),
    );
    addTearDown(db.close);
    final snapshot = (await AssetDao(db).getSnapshots()).single;
    expect(snapshot.totalValue, 1234);
    expect(snapshot.holdingValues, isNull);
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle())
          .data
          .values
          .single,
      13,
    );
  });
}
