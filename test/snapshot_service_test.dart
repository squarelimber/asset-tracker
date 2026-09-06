import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/snapshot_service.dart';

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
}
