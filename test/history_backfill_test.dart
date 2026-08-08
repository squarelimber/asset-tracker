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

  test('backfill generates daily snapshots from purchase date', () async {
    // Holding bought on 2026-07-01 (100 units @ NAV ~2.6).
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '娴嬭瘯璐︽埛',
      type: 'general',
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '娴嬭瘯鍩洪噾',
      assetType: AssetType.mutualFund.storageName,
      marketSource: Value(MarketSource.eastmoney.storageName),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: const Value(2.9),
      purchaseDate: Value(DateTime(2026, 7, 1)),
    ));

    // Fake history for the window.
    final fake = _FakeHistorySource();
    fake.data['110022'] = {
      for (var d = DateTime(2026, 7, 1); !d.isAfter(DateTime(2026, 7, 5)); d = d.add(const Duration(days: 1)))
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}': 2.6,
    };

    final service = HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});
    final result = await service.backfill(now: DateTime(2026, 7, 8));

    expect(result.ok, isTrue);
    expect(result.holdings, 1);
    // Window is 2026-07-01..07-07 (7 days). Days 07-01..07-05 come from
    // history; 07-06/07-07 fall back to latestPrice. -> 7 snapshots.
    expect(result.days, 7);

    final snapshots = await dao.getSnapshots();
    expect(snapshots, hasLength(7));
    // Value = 100 * 2.6 = 260.
    expect(snapshots.first.totalValue, closeTo(260, 1e-6));
  });

  test('backfill does not overwrite existing snapshots', () async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '娴嬭瘯璐︽埛',
      type: 'general',
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '娴嬭瘯鍩洪噾',
      assetType: AssetType.mutualFund.storageName,
      marketSource: Value(MarketSource.eastmoney.storageName),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: const Value(2.9),
      purchaseDate: Value(DateTime(2026, 7, 1)),
    ));
    // Existing snapshot for one of the historical days (simulates today).
    await dao.upsertSnapshot(SnapshotsCompanion.insert(
      date: '2026-07-03',
      currency: const Value('CNY'),
      totalValue: 999,
      totalCost: 250,
    ));

    final fake = _FakeHistorySource();
    fake.data['110022'] = {
      for (var d = DateTime(2026, 7, 1); !d.isAfter(DateTime(2026, 7, 3)); d = d.add(const Duration(days: 1)))
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}': 2.6,
    };

    final service = HistoryBackfillService(dao, sources: {MarketSource.eastmoney: fake});
    await service.backfill(now: DateTime(2026, 7, 8));

    final snapshots = await dao.getSnapshots();
    // 2026-07-03 already existed; the other 6 window days are filled.
    expect(snapshots, hasLength(7));
    final kept = snapshots.firstWhere((s) => s.date == '2026-07-03');
    expect(kept.totalValue, 999);
  });
}
