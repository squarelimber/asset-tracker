import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/history_sync.dart';
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

class _RetryHistory extends _FlatHistorySource {
  _RetryHistory() : super(1);
  bool online = false;

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    if (!online) throw StateError('offline');
    return super.fetch(symbol, from, to);
  }
}

void main() {
  test('an interrupted backfill remains queued until a successful retry', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    final id = await dao.createAccount(AccountsCompanion.insert(name: 'a', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: id, name: 'fund', assetType: 'mutual_fund',
      symbol: const Value('110022'), marketSource: const Value('eastmoney'),
      quantity: const Value(100), costPrice: const Value(1),
      purchaseDate: Value(DateTime.now().subtract(const Duration(days: 15))),
    ));
    await dao.setSetting(historySyncDirtyKey, historyDirtySet);
    final source = _RetryHistory();
    final backfill = HistoryBackfillService(
      dao, sources: {MarketSource.eastmoney: source},
    );
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      tradingCalendarProvider.overrideWith((ref) async {}),
      historyDirtyFlagProvider.overrideWith((ref) => Stream.value(historyDirtySet)),
      historyBackfillServiceProvider.overrideWithValue(backfill),
      marketServiceProvider.overrideWithValue(_FakeMarket(dao, dao)),
    ]);
    addTearDown(container.dispose);
    final subscription = container.listen(historySyncProvider, (_, _) {});
    addTearDown(subscription.close);

    expect((await container.read(historySyncProvider.future))!.historyUnavailable, isTrue);
    expect(await dao.getSetting(historySyncDirtyKey), historyDirtySet);
    expect(await dao.getSetting(historySyncV6Key), isNull);
    source.online = true;
    expect((await container.refresh(historySyncProvider.future))!.ok, isTrue);
    expect(await dao.getSetting(historySyncDirtyKey), historyDirtyClear);
    expect(await dao.getSetting(historySyncV6Key), '1');
  });

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

    // 刷新先行：backfill 写今天时用已刷新的最新价（1.5×100=150），
    // 不再需要第二个覆盖步骤 —— 今天与历史日同源同法。
    expect(fakeMarket.refreshed, isTrue,
        reason: '刷新必须在回填前完成，backfill 才能用新价写今天');
    final now = DateTime.now();
    final key =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final today = await dao.getSnapshot(key, 'CNY');
    expect(today!.totalValue, closeTo(150, 1e-6),
        reason: '刷新后新价 1.5 × 100 份 = 150（backfill 今天用最新价）');

    await db.close();
    await tester.pump();
  });
}
