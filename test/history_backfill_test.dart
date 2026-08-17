import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/daily_earnings.dart';
import 'package:asset_tracker/services/history_backfill_service.dart';
import 'package:asset_tracker/services/market/history_source.dart';

class _FakeHistorySource extends HistoryDataSource {
  _FakeHistorySource() : super(MarketSource.eastmoney);

  final Map<String, DailyPriceHistory> data = {};

  /// Trading days only (Mon-Fri), like real market data.
  static String key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    return data[symbol] ?? {};
  }
}

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

  Future<int> seedFundHolding({DateTime? purchaseDate, double latest = 2.9}) async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试账户',
      type: 'general',
    ));
    return dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '测试基金',
      assetType: AssetType.mutualFund.storageName,
      marketSource: Value(MarketSource.eastmoney.storageName),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: Value(latest),
      purchaseDate: Value(purchaseDate ?? DateTime(2026, 6, 29)),
    ));
  }

  test('backfill generates daily snapshots from purchase date', () async {
    await seedFundHolding(purchaseDate: DateTime(2026, 7, 1));
    final fake = _FakeHistorySource();
    // Trading days 2026-07-01(Wed)..07-03(Fri).
    fake.data['110022'] = {
      for (var d = DateTime(2026, 7, 1); !d.isAfter(DateTime(2026, 7, 3)); d = d.add(const Duration(days: 1)))
        _FakeHistorySource.key(d): 2.6,
    };

    final service = HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});
    final result = await service.backfill(now: DateTime(2026, 7, 8));

    expect(result.ok, isTrue);
    expect(result.holdings, 1);
    // Window 07-01..07-07 = 7 days, all filled.
    expect(result.days, 7);

    final snapshots = await dao.getSnapshots();
    expect(snapshots, hasLength(7));
    expect(snapshots.first.totalValue, closeTo(260, 1e-6));
  });

  test('weekend snapshots forward-fill to the last trading day price', () async {
    await seedFundHolding(purchaseDate: DateTime(2026, 7, 1), latest: 2.9);
    final fake = _FakeHistorySource();
    // Only trading days 07-01..07-03 have history; the latest price is 2.9.
    fake.data['110022'] = {
      for (var d = DateTime(2026, 7, 1); !d.isAfter(DateTime(2026, 7, 3)); d = d.add(const Duration(days: 1)))
        _FakeHistorySource.key(d): 2.6,
    };

    final service = HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});
    await service.backfill(now: DateTime(2026, 7, 8));

    final snapshots = await dao.getSnapshots();
    // Weekend (07-04, 07-05) and beyond must use 2.6 (last trading day),
    // NOT the current latest price 2.9 -> no weekly jumps.
    for (final s in snapshots) {
      expect(s.totalValue, closeTo(260, 1e-6),
          reason: 'snapshot ${s.date} should carry the last trading-day price');
    }
  });

  test('one-time recompute deletes stale historical snapshots', () async {
    await seedFundHolding(purchaseDate: DateTime(2026, 7, 1));
    final fake = _FakeHistorySource();
    fake.data['110022'] = {
      _FakeHistorySource.key(DateTime(2026, 7, 1)): 2.6,
      _FakeHistorySource.key(DateTime(2026, 7, 2)): 2.6,
    };

    // Simulate a stale snapshot written by the old (buggy) version.
    await dao.upsertSnapshot(SnapshotsCompanion.insert(
      date: '2026-07-02',
      currency: const Value('CNY'),
      totalValue: 999,
      totalCost: 250,
    ));

    final service = HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});
    await service.backfill(now: DateTime(2026, 7, 4));

    // The stale 999 snapshot must have been deleted and recomputed as 260.
    final snapshots = await dao.getSnapshots();
    expect(snapshots.any((s) => s.totalValue == 999), isFalse);
    expect(snapshots.firstWhere((s) => s.date == '2026-07-02').totalValue, closeTo(260, 1e-6));
  });

  test('recompute marker prevents deleting snapshots twice', () async {
    await seedFundHolding(purchaseDate: DateTime(2026, 7, 1));
    final fake = _FakeHistorySource();
    fake.data['110022'] = {_FakeHistorySource.key(DateTime(2026, 7, 1)): 2.6};

    final service = HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});
    await service.backfill(now: DateTime(2026, 7, 2));

    // User manually fixes a snapshot after the first backfill.
    final stmt = db.update(db.snapshots)..where((t) => t.date.equals('2026-07-01'));
    await stmt.write(const SnapshotsCompanion(totalValue: Value(888)));

    // Second run must NOT delete/recompute it.
    await service.backfill(now: DateTime(2026, 7, 2));
    final snapshots = await dao.getSnapshots();
    expect(snapshots.single.totalValue, 888);
  });

  test('holdings are excluded before their purchase date', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试账户',
      type: 'general',
    ));
    // Bought 2026-07-03 with history covering the whole window.
    final holdingId = await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '测试基金',
      assetType: AssetType.mutualFund.storageName,
      marketSource: Value(MarketSource.eastmoney.storageName),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: const Value(2.6),
      purchaseDate: Value(DateTime(2026, 7, 3)),
    ));
    final fake = _FakeHistorySource();
    fake.data['110022'] = {
      for (var d = DateTime(2026, 6, 29); !d.isAfter(DateTime(2026, 7, 7)); d = d.add(const Duration(days: 1)))
        _FakeHistorySource.key(d): 2.6,
    };

    final service = HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});
    await service.backfill(now: DateTime(2026, 7, 8));

    final snapshots = await dao.getSnapshots();
    // Window 06-29..07-07 = 9 days; holding exists from 07-03 -> 5 days.
    expect(snapshots, hasLength(5));
    expect(snapshots.first.date, '2026-07-03');
    for (final s in snapshots) {
      expect(s.totalValue, closeTo(260, 1e-6));
    }
    expect(holdingId, isPositive);
  });

  test('forceRebuild merges a newly added holding into existing snapshots', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试账户',
      type: 'general',
    ));
    // Existing holding, snapshots already generated for 07-01..07-03.
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '旧基金',
      assetType: AssetType.mutualFund.storageName,
      marketSource: Value(MarketSource.eastmoney.storageName),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: const Value(2.6),
      purchaseDate: Value(DateTime(2026, 7, 1)),
    ));
    final fake = _FakeHistorySource();
    fake.data['110022'] = {
      for (var d = DateTime(2026, 7, 1); !d.isAfter(DateTime(2026, 7, 3)); d = d.add(const Duration(days: 1)))
        _FakeHistorySource.key(d): 2.6,
    };
    final service = HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});
    await service.backfill(now: DateTime(2026, 7, 4));
    expect(await dao.getSnapshots(), hasLength(3));

    // User adds a second holding bought on 07-01 (backdated).
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '新基金',
      assetType: AssetType.mutualFund.storageName,
      marketSource: Value(MarketSource.eastmoney.storageName),
      symbol: const Value('005827'),
      quantity: const Value(100),
      costPrice: const Value(3.0),
      latestPrice: const Value(3.0),
      purchaseDate: Value(DateTime(2026, 7, 1)),
    ));
    fake.data['005827'] = {
      for (var d = DateTime(2026, 7, 1); !d.isAfter(DateTime(2026, 7, 3)); d = d.add(const Duration(days: 1)))
        _FakeHistorySource.key(d): 3.0,
    };

    // Plain backfill does NOT touch existing days...
    await service.backfill(now: DateTime(2026, 7, 4));
    var snap = await dao.getSnapshots();
    expect(snap.first.totalValue, closeTo(260, 1e-6)); // old value only

    // ...but forceRebuild rewrites them including the new holding.
    await service.backfill(now: DateTime(2026, 7, 4), forceRebuild: true);
    snap = await dao.getSnapshots();
    expect(snap, hasLength(3));
    for (final s in snap) {
      expect(s.totalValue, closeTo(560, 1e-6)); // 260 + 300
    }
  });

  test('amount-based assets smooth from invested to current balance', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试账户',
      type: 'general',
    ));
    // Amount-based: quantity = 5000 balance, costPrice = 4000 invested.
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '现金',
      assetType: AssetType.bankDeposit.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(5000),
      costPrice: const Value(4000),
      latestPrice: const Value(1),
      purchaseDate: Value(DateTime(2026, 7, 1)),
    ));

    final service = HistoryBackfillService(dao, sources: {});
    await service.backfill(now: DateTime(2026, 7, 3));

    final snapshots = await dao.getSnapshots();
    expect(snapshots, isNotEmpty);
    final byDate = {for (final s in snapshots) s.date: s};
    // Smooth accrual: starts at the invested amount and grows geometrically
    // toward the current balance (4000 -> 5000 over 2 days).
    expect(byDate['2026-07-01']!.totalValue, closeTo(4000, 1e-6));
    expect(byDate['2026-07-02']!.totalValue,
        closeTo(4000 * pow(5000 / 4000, 0.5), 1e-6));
    for (final s in snapshots) {
      // Cost must be 4000 (invested), NOT 5000 * 4000.
      expect(s.totalCost, closeTo(4000, 1e-6));
    }
  });

  test('repayment backfills the replayed cost so the transfer day earns zero',
      () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试账户',
      type: 'general',
    ));
    // Repayment on 7/2: cash balance AND cost fell by 5514 together.
    final cashId = await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '现金',
      assetType: AssetType.bankDeposit.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(44486),
      costPrice: const Value(44486),
      latestPrice: const Value(1),
      purchaseDate: Value(DateTime(2026, 7, 1)),
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '信用卡',
      assetType: AssetType.liability.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(0),
      costPrice: const Value(1),
      latestPrice: const Value(1),
      purchaseDate: Value(DateTime(2026, 7, 1)),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: accountId,
      holdingId: const Value.absent(),
      cashSourceId: Value(cashId),
      cashTargetId: Value(cashId + 1),
      type: 'transfer_out',
      amount: 5514,
      currency: const Value('CNY'),
      occurredAt: DateTime(2026, 7, 2, 12),
      costMoved: const Value(true),
    ));

    final service = HistoryBackfillService(dao, sources: {});
    await service.backfill(now: DateTime(2026, 7, 3));

    final snapshots = await dao.getSnapshots();
    final byDate = {for (final s in snapshots) s.date: s};
    // 7/1 (before the repayment): value and cost both carry the
    // pre-repayment principal (50000), so the transfer is not attributed
    // a phantom gain/loss on any day. 7/3 is "today" (handled by the daily
    // snapshot), so the backfill window ends at 7/2.
    expect(snapshots, hasLength(2));
    expect(byDate['2026-07-01']!.totalValue, closeTo(50000, 1e-6));
    expect(byDate['2026-07-01']!.totalCost, closeTo(50000, 1e-6));
    expect(byDate['2026-07-02']!.totalValue, closeTo(44486, 1e-6));
    expect(byDate['2026-07-02']!.totalCost, closeTo(44486, 1e-6));

    // The repayment day reports zero profit.
    final earning = const DailyEarningsCalculator()
        .compute(snapshots)
        .firstWhere((e) => e.date == '2026-07-02');
    expect(earning.profit, closeTo(0, 1e-9));
  });
}
