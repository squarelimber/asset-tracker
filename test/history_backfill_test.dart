import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
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
}
