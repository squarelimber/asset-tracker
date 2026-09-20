import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/market/market_service.dart';
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

  // A foreign-currency holding whose rate cannot be obtained used to be
  // valued at parity (`valueRateOf` falls back to 1), dropping the whole FX
  // leg from net worth while still producing a plausible-looking total. The
  // snapshot then merges to every other device with last-write-wins, so the
  // wrong figure does not stay local. Refusing to write is the only safe
  // response: an empty cell can be filled in later, a synchronised wrong
  // total cannot.
  group('汇率拿不到时不写快照', () {
    // 银行理财 is share-based (cost = quantity x unit cost), and carries
    // `forex` as its "no live NAV" marker — but the symbol is a *product*
    // code, not a currency, so it is not rate-linked and still needs a real
    // USD rate to convert.
    Future<int> seedUsdHolding() async {
      final accountId = await dao.createAccount(
          AccountsCompanion.insert(name: '境外账户', type: 'general'));
      return dao.createHolding(HoldingsCompanion.insert(
        accountId: accountId,
        name: '美元理财',
        assetType: AssetType.bankWealth.storageName,
        marketSource: Value(MarketSource.forex.storageName),
        symbol: const Value('Y05A9W10006A'),
        quantity: const Value(1000),
        costPrice: const Value(6.9),
        latestPrice: const Value(7.0),
        currency: const Value('USD'),
        purchaseDate: Value(DateTime(2026, 1, 1)),
      ));
    }

    test('没有汇率时整天跳过，而不是按 1 折算', () async {
      await seedUsdHolding();
      // No market service and no cached rate: exactly the state a fresh
      // device is in before its first successful refresh.
      final service = SnapshotService(dao, clock: () => DateTime(2026, 9, 4));
      await service.ensureTodaySnapshot();

      expect(await dao.getSnapshots(), isEmpty);
    });

    test('汇率齐全时按汇率折算写出正确金额', () async {
      await seedUsdHolding();
      // `loadCnyRates` judges freshness against the *real* clock, so the
      // cached rate must be stamped "now": an older stamp counts as stale,
      // and the live re-fetch that follows is exactly the network
      // dependency this test must not have.
      final now = DateTime.now();
      await dao.upsertPriceCache(PriceCacheRow(
        symbol: 'USD',
        source: 'forex',
        name: '美元',
        price: 7.15,
        currency: 'USD',
        fetchedAt: now,
      ));

      final service = SnapshotService(
        dao,
        clock: () => now,
        market: MarketService(dao),
      );
      await service.ensureTodaySnapshot();

      final snap = (await dao.getSnapshots()).single;
      expect(snap.totalValue, closeTo(1000 * 7.0 * 7.15, 1e-6));
      expect(snap.totalCost, closeTo(1000 * 6.9 * 7.15, 1e-6));
    });

    test('汇率联动持仓（代码即货币）不需要汇率表', () async {
      final accountId = await dao.createAccount(
          AccountsCompanion.insert(name: '境外账户', type: 'general'));
      await dao.createHolding(HoldingsCompanion.insert(
        accountId: accountId,
        name: '美元存款',
        assetType: AssetType.bankWealth.storageName,
        marketSource: Value(MarketSource.forex.storageName),
        // Code *is* the currency: latestPrice already carries the rate, so
        // no second conversion may be applied and no rate is needed.
        symbol: const Value('USD'),
        quantity: const Value(10000),
        costPrice: const Value(10000),
        latestPrice: const Value(7.1),
        currency: const Value('USD'),
        purchaseDate: Value(DateTime(2026, 1, 1)),
      ));

      final service = SnapshotService(dao, clock: () => DateTime(2026, 9, 4));
      await service.ensureTodaySnapshot();

      final snap = (await dao.getSnapshots()).single;
      expect(snap.totalValue, closeTo(10000 * 7.1, 1e-6));
    });
  });
}
