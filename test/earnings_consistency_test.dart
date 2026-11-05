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
}) => DayHoldingValue(
  holdingId: id,
  name: '产品$id',
  type: debt ? AssetType.liability : AssetType.etf,
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

  test(
    'snapshot errors propagate instead of becoming an empty calendar',
    () async {
      final container = ProviderContainer(
        overrides: [
          snapshotsProvider.overrideWith(
            (ref) => Stream.error(StateError('read failed')),
          ),
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
        overrides: [snapshotsProvider.overrideWith((ref) => stream.stream)],
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
