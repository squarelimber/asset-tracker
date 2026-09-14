import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/snapshot_service.dart';
import 'package:asset_tracker/sync/sync_format.dart';

void main() {
  late AppDatabase db;
  late AssetDao dao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedFundHolding() async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试账户',
      type: 'general',
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '测试基金',
      assetType: AssetType.mutualFund.storageName,
      marketSource: Value(MarketSource.eastmoney.storageName),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: const Value(2.9),
      purchaseDate: Value(DateTime(2026, 6, 29)),
    ));
  }

  test('does not record a snapshot when there are no holdings', () async {
    // A fresh install / not-yet-synced device has an empty holdings table.
    // Recording a zero snapshot here would corrupt the net-worth trend and,
    // because snapshots sync with last-write-wins, push that corruption to
    // every other device.
    final service = SnapshotService(dao, clock: () => DateTime(2026, 9, 4));
    await service.ensureTodaySnapshot();

    expect(await dao.getSnapshots(), isEmpty);
  });

  test('records a snapshot when holdings exist', () async {
    await seedFundHolding();
    final service = SnapshotService(dao, clock: () => DateTime(2026, 9, 4));
    await service.ensureTodaySnapshot();

    final snapshots = await dao.getSnapshots();
    expect(snapshots, hasLength(1));
    // 100 shares × 2.9 = 290 market value; cost 100 × 2.5 = 250.
    expect(snapshots.single.totalValue, closeTo(290, 1e-6));
    expect(snapshots.single.totalCost, closeTo(250, 1e-6));
    expect(snapshots.single.date, '2026-09-04');
  });

  test('is idempotent for the same day', () async {
    await seedFundHolding();
    final service = SnapshotService(dao, clock: () => DateTime(2026, 9, 4));
    await service.ensureTodaySnapshot();
    await service.ensureTodaySnapshot();

    expect(await dao.getSnapshots(), hasLength(1));
  });

  test('a forced rewrite bumps the sync version', () async {
    await seedFundHolding();
    final morning = DateTime(2026, 9, 4, 9);
    final evening = DateTime(2026, 9, 4, 19);
    var now = morning;
    final service = SnapshotService(dao, clock: () => now);

    await service.ensureTodaySnapshot();
    final first = (await dao.getSnapshots()).single;
    expect(first.createdAt, morning);

    // A snapshot is derived data and gets recomputed whenever the prices or
    // holdings behind it change. `createdAt` doubles as the cross-device
    // last-write-wins version (see SyncFormatter.snapshotToRow), so the
    // rewrite has to move it — otherwise a corrected value can never
    // displace the stale row it was meant to fix on another device.
    now = evening;
    await service.ensureTodaySnapshot(force: true);
    final second = (await dao.getSnapshots()).single;
    expect(second.createdAt, evening);
    expect(second.createdAt.isAfter(first.createdAt), isTrue);
    expect(
      const SyncFormatter().snapshotToRow(second)['updatedAt'],
      evening.toIso8601String(),
    );
  });

  test('a non-forced run never overwrites an existing day', () async {
    await seedFundHolding();
    final service = SnapshotService(dao, clock: () => DateTime(2026, 9, 4));
    await service.ensureTodaySnapshot();
    // Simulate a hand-corrected value.
    await (db.update(db.snapshots)..where((t) => t.date.equals('2026-09-04')))
        .write(const SnapshotsCompanion(totalValue: Value(12345)));

    // A refresh that failed must not rewrite the day from stale prices.
    await service.ensureTodaySnapshot();

    expect((await dao.getSnapshots()).single.totalValue, 12345);
  });
}
