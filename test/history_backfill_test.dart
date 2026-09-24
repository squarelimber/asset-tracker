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

/// A source whose fetch throws (simulates a network failure).
class _ThrowingHistorySource extends HistoryDataSource {
  _ThrowingHistorySource() : super(MarketSource.eastmoney);

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    throw Exception('network error for $symbol');
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
    // Window 07-01..07-08 (today included) = 8 days, all filled.
    expect(result.days, 8);
    // The run owns today, so callers may skip the live-quote fallback writer.
    expect(result.wroteToday, isTrue);

    final snapshots = await dao.getSnapshots();
    expect(snapshots, hasLength(8));
    expect(snapshots.first.totalValue, closeTo(260, 1e-6));
  });

  test('the window includes today so the live and history paths agree', () async {
    await seedFundHolding(purchaseDate: DateTime(2026, 7, 1), latest: 2.9);
    final fake = _FakeHistorySource();
    // History only covers 07-01..07-03; the fake's series therefore also
    // stands in for the value of today (07-08, a Wednesday).
    fake.data['110022'] = {
      for (var d = DateTime(2026, 7, 1); !d.isAfter(DateTime(2026, 7, 3)); d = d.add(const Duration(days: 1)))
        _FakeHistorySource.key(d): 2.6,
    };

    final service = HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});
    final now = DateTime(2026, 7, 8);
    await service.backfill(now: now);

    final snapshots = await dao.getSnapshots();
    final today = snapshots.where((s) => s.date == '2026-07-08');
    // Today used to be written by the live-quote path only and was excluded
    // from the rebuild, which is how a disagreement between the two paths
    // became a single-day spike. The rebuild now owns today as well, priced
    // from the same series as every other day.
    expect(today, hasLength(1));
    expect(today.single.totalValue, closeTo(260, 1e-6));
    expect((await dao.getSnapshot('2026-07-08', 'CNY'))?.date, '2026-07-08');
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

    // Second run must NOT delete/recompute the historical day (today is
    // always re-derived, so only the non-today row is asserted here).
    await service.backfill(now: DateTime(2026, 7, 2));
    final snapshots = await dao.getSnapshots();
    expect(
      snapshots.firstWhere((s) => s.date == '2026-07-01').totalValue,
      888,
    );
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
    // Window 06-29..07-08 = 10 days; holding exists from 07-03 -> 6 days.
    expect(snapshots, hasLength(6));
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
    expect(await dao.getSnapshots(), hasLength(4));

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
    expect(snap, hasLength(4));
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
    // a phantom gain/loss on any day. 7/3 is today, and is now part of the
    // same window (it used to be written by the daily-snapshot path alone).
    expect(snapshots, hasLength(3));
    expect(byDate['2026-07-01']!.totalValue, closeTo(50000, 1e-6));
    expect(byDate['2026-07-01']!.totalCost, closeTo(50000, 1e-6));
    expect(byDate['2026-07-02']!.totalValue, closeTo(44486, 1e-6));
    expect(byDate['2026-07-02']!.totalCost, closeTo(44486, 1e-6));
    expect(byDate['2026-07-03']!.totalValue, closeTo(44486, 1e-6));
    expect(byDate['2026-07-03']!.totalCost, closeTo(44486, 1e-6));

    // The repayment day reports zero profit.
    final earning = const DailyEarningsCalculator()
        .compute(snapshots)
        .firstWhere((e) => e.date == '2026-07-02');
    expect(earning.profit, closeTo(0, 1e-9));
  });

  test('a failed history fetch aborts the rebuild and writes no snapshots',
      () async {
    await seedFundHolding(purchaseDate: DateTime(2026, 7, 1));
    final service =
        HistoryBackfillService(dao, sources: {MarketSource.eastmoney: _ThrowingHistorySource()});

    final result = await service.backfill(now: DateTime(2026, 7, 8));

    // The fetch threw -> the rebuild must abort and write nothing, rather
    // than substituting the current price for every historical date.
    expect(result.ok, isFalse);
    expect(result.days, 0);
    // The abort reason must be visible to callers: they may not rewrite
    // today's snapshot in this state either (the quotes are equally
    // unreliable), see HistorySyncProvider.
    expect(result.historyUnavailable, isTrue);
    expect(result.wroteToday, isFalse);
    expect(result.message, contains('110022'));
    expect(result.message, contains('未写入'));
    expect(await dao.getSnapshots(), isEmpty);
  });

  test('an empty history (newly added holding) does not abort the rebuild',
      () async {
    // A holding bought today with no fetched history yet: the source returns
    // an empty series (not an error). The backfill must still succeed and
    // carry the holding at its latest price for the (single) day.
    await seedFundHolding(purchaseDate: DateTime(2026, 7, 7), latest: 2.9);
    final fake = _FakeHistorySource(); // returns {} for 110022
    final service = HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});

    final result = await service.backfill(now: DateTime(2026, 7, 8));

    expect(result.ok, isTrue);
    final snapshots = await dao.getSnapshots();
    // Window is 07-07 (purchase date) .. 07-08 (today); both are carried at
    // the latest price 2.9*100.
    expect(snapshots, hasLength(2));
    for (final s in snapshots) {
      expect(s.totalValue, closeTo(290, 1e-6));
    }
  });

  group('a day frozen by the live path is re-derived', () {
    /// A day is written twice: the backfill prices it from the closing
    /// series, then the live path overwrites it from intraday quotes when the
    /// user refreshes. A day whose last write happened mid-session stays
    /// frozen at that value, and because the daily return is the difference
    /// of two snapshots, it understates the *next* day as well.
    /// Re-deriving today alone (the pre-fix behaviour) never repaired it.

    Future<Map<String, double>> series(DateTime from, DateTime to) async => {
          for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1)))
            _FakeHistorySource.key(d): 2.6,
        };

    test('on the next launch, so the following day returns to normal',
        () async {
      await seedFundHolding(purchaseDate: DateTime(2026, 7, 1), latest: 2.9);
      final fake = _FakeHistorySource();
      fake.data['110022'] = await series(DateTime(2026, 7, 1), DateTime(2026, 7, 8));
      final service =
          HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});

      // First launch on 07-07 (a Tuesday). The backfill derives the day at
      // the closing 2.6, then a mid-session refresh freezes it at 2.9.
      await service.backfill(now: DateTime(2026, 7, 7));
      await dao.upsertSnapshot(SnapshotsCompanion.insert(
        date: '2026-07-07',
        currency: const Value('CNY'),
        totalValue: 290,
        totalCost: 250,
        createdAt: Value(DateTime(2026, 7, 7, 13, 45)),
      ));

      // Next launch on 07-08. With only today re-derived the frozen 07-07
      // stayed put and 07-08 reported 260 - 290 = -30 instead of 0.
      await service.backfill(now: DateTime(2026, 7, 8));

      final snapshots = await dao.getSnapshots();
      expect(
        snapshots.firstWhere((s) => s.date == '2026-07-07').totalValue,
        closeTo(260, 1e-6),
        reason: 'the intraday-frozen day must go back on the closing series',
      );
      final earning = const DailyEarningsCalculator()
          .compute(snapshots)
          .firstWhere((e) => e.date == '2026-07-08');
      expect(earning.profit, closeTo(0, 1e-6));
    });

    test('even after a long gap between launches', () async {
      await seedFundHolding(purchaseDate: DateTime(2026, 7, 1), latest: 2.9);
      final fake = _FakeHistorySource();
      fake.data['110022'] =
          await series(DateTime(2026, 7, 1), DateTime(2026, 7, 11));
      final service =
          HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});

      // Launch on 07-03, then the live path freezes the day mid-session.
      await service.backfill(now: DateTime(2026, 7, 3));
      await dao.upsertSnapshot(SnapshotsCompanion.insert(
        date: '2026-07-03',
        currency: const Value('CNY'),
        totalValue: 290,
        totalCost: 250,
        createdAt: Value(DateTime(2026, 7, 3, 13, 45)),
      ));

      // The app is not opened again until 07-11. A fixed "today + yesterday"
      // window would skip 07-03 entirely; anchoring the window on the
      // previous run's date re-derives the whole span instead.
      await service.backfill(now: DateTime(2026, 7, 11));

      final snapshots = await dao.getSnapshots();
      expect(snapshots, hasLength(11)); // 07-01 .. 07-11
      expect(
        snapshots.firstWhere((s) => s.date == '2026-07-03').totalValue,
        closeTo(260, 1e-6),
      );
    });

    test('but a day before the previous run is still left alone', () async {
      await seedFundHolding(purchaseDate: DateTime(2026, 7, 1), latest: 2.9);
      final fake = _FakeHistorySource();
      fake.data['110022'] = await series(DateTime(2026, 7, 1), DateTime(2026, 7, 4));
      final service =
          HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});

      await service.backfill(now: DateTime(2026, 7, 4));
      // A user edit that must survive the next light run: 07-02 predates the
      // anchor (07-04), so it is not part of the repaired span.
      final stmt = db.update(db.snapshots)
        ..where((t) => t.date.equals('2026-07-02'));
      await stmt.write(const SnapshotsCompanion(totalValue: Value(777)));

      await service.backfill(now: DateTime(2026, 7, 4));

      final snapshots = await dao.getSnapshots();
      expect(
        snapshots.firstWhere((s) => s.date == '2026-07-02').totalValue,
        777,
      );
    });
  });

  group('a light run with no previous-run anchor', () {
    /// The first launch after the anchored window shipped: the one-off
    /// rebuild marker is already set and `backfill_last_run` was never
    /// written, so there is nothing to anchor to. Collapsing to "today only"
    /// here would leave a frozen day in place on exactly the devices that are
    /// most likely to be carrying one.

    test('falls back to a fixed week, repairing inside and sparing outside',
        () async {
      await dao.setSetting('backfill_v7_gold_spot_and_today', '1');
      await dao.setSetting('backfill_v8_share_replay', '1');
      // v9 (smooth share replay) migrated too: this is a fully current
      // database, so the run below is a plain light run. The one-time full
      // rebuild for databases missing the v9 marker is covered by
      // smooth_share_replay_test.dart.
      await dao.setSetting('backfill_v9_smooth_share_replay', '1');
      await seedFundHolding(purchaseDate: DateTime(2026, 7, 1), latest: 2.9);
      final fake = _FakeHistorySource();
      fake.data['110022'] = {
        for (var d = DateTime(2026, 7, 1);
            !d.isAfter(DateTime(2026, 7, 16));
            d = d.add(const Duration(days: 1)))
          _FakeHistorySource.key(d): 2.6,
      };

      Future<void> seedDay(String date, double value) => dao.upsertSnapshot(
            SnapshotsCompanion.insert(
              date: date,
              currency: const Value('CNY'),
              totalValue: value,
              totalCost: 250,
            ),
          );
      // 07-13 was frozen mid-session by the live path and sits inside the
      // fallback week; 07-09 is exactly on the boundary (today - 7) and is
      // also inside; 07-08 is one day past it and must survive untouched.
      await seedDay('2026-07-08', 999);
      await seedDay('2026-07-09', 888);
      await seedDay('2026-07-13', 290);

      final service =
          HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});
      await service.backfill(now: DateTime(2026, 7, 16));

      final byDate = {for (final s in await dao.getSnapshots()) s.date: s};
      expect(byDate, hasLength(16)); // 07-01 .. 07-16
      expect(byDate['2026-07-13']!.totalValue, closeTo(260, 1e-6),
          reason: 'a frozen day inside the fallback week must be re-derived');
      expect(byDate['2026-07-09']!.totalValue, closeTo(260, 1e-6),
          reason: 'the boundary day (today - 7) is inside the window');
      expect(byDate['2026-07-08']!.totalValue, 999,
          reason: 'a day past the fallback week is left alone');
    });
  });

  test('a transfer that empties an account leaves no phantom cost behind',
      () async {
    // The real 2026-09-18 sequence: 余额宝 (balance 117,303.20, invested
    // 115,364.71) was emptied into 现金账户 by a 117,327.38 transfer, and the
    // cash account then paid 13,642.20 for an ETF. The replay used to report
    // 余额宝's *pre*-transfer principal as the transfer day's invested amount
    // while its value was already 0, so that day's cost came out 117,327.38
    // too high — the overview showed a fake "-114,713.84 today earning" on
    // every cold start until a price refresh overwrote the day from the
    // holdings table.
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '测试账户',
      type: 'general',
    ));
    final yuebaoId = await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '余额宝',
      assetType: 'bank_deposit',
      marketSource: const Value('manual'),
      quantity: const Value(0),
      costPrice: const Value(0),
      latestPrice: const Value(1),
      purchaseDate: Value(DateTime(2026, 9, 1)),
    ));
    final cashId = await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '现金账户',
      assetType: 'savings',
      marketSource: const Value('manual'),
      quantity: const Value(122182.66),
      costPrice: const Value(122216.00),
      latestPrice: const Value(1),
      purchaseDate: Value(DateTime(2026, 9, 1)),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: accountId,
      holdingId: const Value.absent(),
      cashSourceId: Value(yuebaoId),
      cashTargetId: Value(cashId),
      type: 'transfer_out',
      amount: 117327.38,
      currency: const Value('CNY'),
      occurredAt: DateTime(2026, 9, 18, 10, 16, 8),
      costMoved: const Value(true),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: accountId,
      holdingId: const Value.absent(),
      cashSourceId: Value(cashId),
      type: 'buy',
      amount: 13642.20,
      currency: const Value('CNY'),
      occurredAt: DateTime(2026, 9, 18, 10, 45, 48),
      costMoved: const Value(true),
    ));

    final service = HistoryBackfillService(dao, sources: {});
    await service.backfill(now: DateTime(2026, 9, 18));

    final snapshots = await dao.getSnapshots();
    final byDate = {for (final s in snapshots) s.date: s};
    // The rebuilt day must carry the holdings' own invested amounts
    // (0 + 122,216.00) — the same figure the live refresh path writes, so the
    // two writers for today's row agree instead of one of them adding the
    // whole transfer on top.
    expect(byDate['2026-09-18']!.totalCost, closeTo(122216.00, 1e-6));
    expect(byDate['2026-09-18']!.totalValue, closeTo(122182.66, 1e-6));
    final earning = const DailyEarningsCalculator()
        .compute(snapshots)
        .firstWhere((e) => e.date == '2026-09-18');
    // Only the cash account's own 33.34 of accrued loss, not -117,327.38.
    expect(earning.profit, closeTo(0, 100),
        reason: 'a full transfer-out must not be booked as a one-day loss');
  });
}
