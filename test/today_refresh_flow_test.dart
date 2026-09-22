import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/history_backfill_service.dart';
import 'package:asset_tracker/services/market/history_source.dart';
import 'package:asset_tracker/services/market/market_service.dart';

/// Flat history source (no price moves).
class _FlatHistorySource extends HistoryDataSource {
  _FlatHistorySource(this.price) : super(MarketSource.eastmoney);

  final double price;

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    final out = <String, double>{};
    for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1))) {
      out['${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'] = price;
    }
    return out;
  }
}

/// Fake market: a refresh "fetches" a new price (1.5) for the single holding.
class _FakeMarket extends MarketService {
  _FakeMarket(super.dao, this._dao);

  final AssetDao _dao;
  bool refreshed = false;

  @override
  Future<MarketRefreshResult> refreshAll() async {
    refreshed = true;
    final h = (await _dao.getHoldings()).single;
    await _dao.updateHolding(h.copyWith(latestPrice: 1.5));
    return MarketRefreshResult(
      updated: 1,
      failed: 0,
      fetchedAt: DateTime.now(),
    );
  }
}

/// Host: watching the history sync (like the portfolio page does).
class _Host extends ConsumerWidget {
  const _Host();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(historySyncProvider);
    return Text(r.value?.message ?? 'loading');
  }
}

void main() {
  testWidgets('冷启动回填后自动刷新行情并重写今天快照（今日收益无需手动刷新）',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final acc = await dao.createAccount(
        AccountsCompanion.insert(name: 'a', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '基金',
      assetType: AssetType.mutualFund.storageName,
      marketSource: const Value('eastmoney'),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: const Value(1.0), // 缓存旧价
      purchaseDate: Value(DateTime(2026, 3, 1)),
    ));

    final fakeMarket = _FakeMarket(dao, dao);
    final backfill = HistoryBackfillService(
      dao,
      sources: {MarketSource.eastmoney: _FlatHistorySource(1.0)},
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        historyBackfillServiceProvider.overrideWithValue(backfill),
        marketServiceProvider.overrideWithValue(fakeMarket),
      ],
      child: const MaterialApp(home: Scaffold(body: _Host())),
    ));
    await tester.pumpAndSettle();

    // 回填写完今天（旧价 1.0×100=100）后，自动刷新并以新价重写今天。
    expect(fakeMarket.refreshed, isTrue,
        reason: '旧行为：wroteToday 后跳过刷新，今天停留在旧价，'
            '今日收益需手动刷新才对');
    final now = DateTime.now();
    final key =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final today = await dao.getSnapshot(key, 'CNY');
    expect(today!.totalValue, closeTo(150, 1e-6),
        reason: '刷新后新价 1.5 × 100 份 = 150');

    await db.close();
    await tester.pump();
  });
}