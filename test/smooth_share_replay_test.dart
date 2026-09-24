import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_details.dart';
import 'package:asset_tracker/domain/smooth_history.dart';
import 'package:asset_tracker/services/history_backfill_service.dart';
import 'package:asset_tracker/services/product_earnings_service.dart';

/// Regression tests for the 2026-09-24「变更账户所属后整个资产/趋势图变化」
/// report. Root cause: share-based **smoothed** holdings (manual-NAV / FX-
/// linked bank wealth, e.g. 月月宝) were valued on every historical day with
/// the *current* quantity, so once a full history rebuild ran after a partial
/// redemption, every pre-redemption day collapsed by the redeemed market
/// value (~112k in the report). The fix replays their buy/sell flows — the
/// same [HoldingReplay] the market-linked holdings use since v8.
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

  /// A share-based smoothed holding: 100 shares @ cost 1 bought 2026-08-01,
  /// 40 redeemed 2026-09-01 at 2 -> 60 shares today. Manual market source
  /// => [isSmoothedHolding] true, share-based => the buggy path pre-fix.
  Future<int> seedSmoothedShareHolding() async {
    final acc = await dao.createAccount(
        AccountsCompanion.insert(name: 'a', type: 'general'));
    final holdingId = await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '月月宝',
      assetType: AssetType.bankWealth.storageName,
      marketSource: const Value('manual'),
      symbol: const Value.absent(),
      quantity: const Value(60), // post-redemption
      costPrice: const Value(1),
      latestPrice: const Value(2),
      purchaseDate: Value(DateTime(2026, 8, 1)),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: acc,
      holdingId: Value(holdingId),
      type: TransactionType.buy.storageName,
      quantity: const Value(100),
      price: const Value(1),
      amount: 100,
      currency: const Value('CNY'),
      occurredAt: DateTime(2026, 8, 1),
      costMoved: const Value(false),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: acc,
      holdingId: Value(holdingId),
      type: TransactionType.sell.storageName,
      quantity: const Value(40),
      price: const Value(2),
      amount: 80,
      currency: const Value('CNY'),
      occurredAt: DateTime(2026, 9, 1),
      costMoved: const Value(false),
    ));
    return holdingId;
  }

  test('回填：部分赎回后，赎回日之前的份额保持赎回前数量（不全曲线塌陷）',
      () async {
    final holdingId = await seedSmoothedShareHolding();
    final h = (await dao.getHoldings()).firstWhere((x) => x.id == holdingId);

    final result = await HistoryBackfillService(dao, sources: const {})
        .backfill(now: DateTime(2026, 9, 10));
    expect(result.ok, isTrue);

    const calc = SmoothHistoryCalculator();
    final from = DateTime(2026, 8, 1);
    final to = DateTime(2026, 9, 10);
    double price(DateTime day) => calc.sharePrice(h, day, from, to);

    // 赎回日（09-01）之前：保持 100 份（旧行为按当前 60 份 → 曲线塌陷）。
    final before =
        (await dao.getSnapshots()).firstWhere((s) => s.date == '2026-08-31');
    expect(before.totalValue, closeTo(100 * price(DateTime(2026, 8, 31)), 1e-6),
        reason: '旧行为：赎回前的每一天都被按赎回后的 60 份估值，整个趋势塌掉');
    expect(before.totalCost, closeTo(100, 1e-6));

    // 赎回日当天起：60 份。
    final after =
        (await dao.getSnapshots()).firstWhere((s) => s.date == '2026-09-01');
    expect(after.totalValue, closeTo(60 * price(DateTime(2026, 9, 1)), 1e-6));
    expect(after.totalCost, closeTo(60, 1e-6));

    // 今天仍按当前持仓（60 份 × 最新价 2 = 120）。
    final today =
        (await dao.getSnapshots()).firstWhere((s) => s.date == '2026-09-10');
    expect(today.totalValue, closeTo(120, 1e-6));
    expect(today.totalCost, closeTo(60, 1e-6));
  });

  test('v9 标记：老库（v7/v8 已跑）首次打开自动全量重建', () async {
    final holdingId = await seedSmoothedShareHolding();
    final h = (await dao.getHoldings()).firstWhere((x) => x.id == holdingId);

    // 老版本标记都已存在（v7、v8 跑过），v9 标记不存在 → 应全量重算，
    // 覆盖锚点（backfill_last_run）之前的旧口径快照。
    await dao.setSetting('backfill_v7_gold_spot_and_today',
        '${DateTime(2026, 1, 1).millisecondsSinceEpoch}');
    await dao.setSetting('backfill_v8_share_replay',
        '${DateTime(2026, 1, 1).millisecondsSinceEpoch}');
    await dao.setSetting('backfill_last_run', '2026-08-01');
    // 预置一条「塌陷后的错误快照」（按 60 份估值，旧代码全量重建产物）。
    await dao.upsertSnapshot(SnapshotsCompanion.insert(
      date: '2026-08-31',
      currency: const Value('CNY'),
      totalValue: 60,
      totalCost: 60,
      liabilities: const Value(0),
      createdAt: Value(DateTime(2026, 8, 31, 10)),
    ));

    final result = await HistoryBackfillService(dao, sources: const {})
        .backfill(now: DateTime(2026, 9, 10));
    expect(result.ok, isTrue);

    const calc = SmoothHistoryCalculator();
    final price = calc.sharePrice(h, DateTime(2026, 8, 31),
        DateTime(2026, 8, 1), DateTime(2026, 9, 10));
    final s = await dao.getSnapshot('2026-08-31', 'CNY');
    expect(s, isNotNull);
    expect(s!.totalValue, closeTo(100 * price, 1e-6),
        reason: '全量重建必须按回放份额（100 份）覆盖旧的塌陷快照');
    // 标记已写入，下次 light run 恢复正常窗口。
    expect(await dao.getSetting('backfill_v9_smooth_share_replay'), isNotNull);
  });

  test('日明细：赎回日之前按赎回前份额（当日市值=100×单价）', () async {
    await seedSmoothedShareHolding();
    final service = HoldingDetailService(dao, sources: const {});

    final before = await service.compute(DateTime(2026, 8, 31));
    expect(before, isNotNull);
    final item = before!.items.single;
    // Query-day window 08-01..08-31 => interpolated price ends at latest (2).
    expect(item.marketValue, closeTo(200, 1e-6),
        reason: '旧行为按当前 60 份 → 120，赎回前的历史被错误压缩');
    expect(item.cost, closeTo(100, 1e-6));

    final after = await service.compute(DateTime(2026, 9, 1));
    final afterItem = after!.items.single;
    expect(afterItem.marketValue, closeTo(120, 1e-6)); // 60 × 2
    expect(afterItem.cost, closeTo(60, 1e-6));
  });

  test('产品收益日历：赎回日之前的份额同样按回放份额', () async {
    final holdingId = await seedSmoothedShareHolding();
    final h = (await dao.getHoldings()).firstWhere((x) => x.id == holdingId);

    final service = ProductEarningsService(dao, sources: const {});
    final products = await service.compute(
      from: DateTime(2026, 8, 1),
      to: DateTime(2026, 9, 10),
    );
    expect(products, hasLength(1));
    final daily = products.single.daily.toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    const calc = SmoothHistoryCalculator();
    double price(String key) {
      final d = DateTime.parse(key);
      return calc.sharePrice(
          h, d, DateTime(2026, 8, 1), DateTime(2026, 9, 10));
    }

    final before = daily.firstWhere((d) => d.date == '2026-08-31');
    expect(before.value, closeTo(100 * price('2026-08-31'), 1e-6));
    expect(before.cost, closeTo(100, 1e-6));
    final after = daily.firstWhere((d) => d.date == '2026-09-01');
    expect(after.value, closeTo(60 * price('2026-09-01'), 1e-6));
    expect(after.cost, closeTo(60, 1e-6));
  });
}