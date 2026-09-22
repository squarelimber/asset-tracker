import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/history_backfill_service.dart';
import 'package:asset_tracker/services/market/history_source.dart';

/// Fake history source pricing every symbol at a constant [price] over the
/// whole window, so the daily move is exactly the share-quantity effect.
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

  Future<BackfillResult> run(DateTime now) async {
    return HistoryBackfillService(dao,
            sources: {MarketSource.eastmoney: _FlatHistorySource(2.6)})
        .backfill(now: now);
  }

  test('清仓基金在其持有期内记入真实市值，卖出日归零并由回款对冲', () async {
    // 3-01 买入 100 份；9-02 全部卖出回款入现金。今天 qty=0（已清仓）。
    final acc = await dao.createAccount(
        AccountsCompanion.insert(name: 'a', type: 'general'));
    final cashId = await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '现金',
      assetType: AssetType.cash.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(260), // 9-02 卖出回款后余额
      costPrice: const Value(260),
      latestPrice: const Value(1),
      purchaseDate: Value(DateTime(2026, 3, 1)),
    ));
    final fundId = await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '易方达清仓',
      assetType: AssetType.mutualFund.storageName,
      marketSource: const Value('eastmoney'),
      symbol: const Value('110022'),
      quantity: const Value(0), // 已清仓
      costPrice: const Value(2.5),
      latestPrice: const Value(2.6),
      purchaseDate: Value(DateTime(2026, 3, 1)),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: acc,
      holdingId: Value(fundId),
      type: TransactionType.buy.storageName,
      quantity: const Value(100),
      price: const Value(2.5),
      amount: 250,
      currency: const Value('CNY'),
      occurredAt: DateTime(2026, 3, 1),
      costMoved: const Value(false),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: acc,
      holdingId: Value(fundId),
      cashTargetId: Value(cashId),
      type: TransactionType.sell.storageName,
      quantity: const Value(100),
      price: const Value(2.6),
      amount: 260,
      currency: const Value('CNY'),
      occurredAt: DateTime(2026, 9, 2),
      costMoved: const Value(false),
    ));

    final r = await run(DateTime(2026, 9, 10));
    expect(r.ok, isTrue);

    // 持有期内（9-01）：基金 100 份 × 2.6 = 260（旧行为按当前 0 份 → 无市值）。
    final sep1 = (await dao.getSnapshots()).firstWhere((s) => s.date == '2026-09-01');
    expect(sep1.totalValue, closeTo(260, 1e-6),
        reason: '旧行为：已清仓基金历史市值恒为 0，9-01 净值应缺失基金市值');
    // 卖出后（9-02）：基金归零，现金回款 260 → 净值连续（赎回=内部转换）。
    final sep2 = (await dao.getSnapshots()).firstWhere((s) => s.date == '2026-09-02');
    expect(sep2.totalValue, closeTo(260, 1e-6));
  });

  test('部分卖出：卖出日之前的份额 = 当前份额 + 已卖出份额', () async {
    // 3-01 买入 150 份；9-02 卖出 50 份（回款入现金）。当前 100 份。
    final acc = await dao.createAccount(
        AccountsCompanion.insert(name: 'a', type: 'general'));
    final cashId = await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '现金',
      assetType: AssetType.cash.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(130),
      costPrice: const Value(130),
      latestPrice: const Value(1),
      purchaseDate: Value(DateTime(2026, 3, 1)),
    ));
    final fundId = await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '半导体',
      assetType: AssetType.mutualFund.storageName,
      marketSource: const Value('eastmoney'),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: const Value(2.6),
      purchaseDate: Value(DateTime(2026, 3, 1)),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: acc,
      holdingId: Value(fundId),
      type: TransactionType.buy.storageName,
      quantity: const Value(150),
      price: const Value(2.5),
      amount: 375,
      currency: const Value('CNY'),
      occurredAt: DateTime(2026, 3, 1),
      costMoved: const Value(false),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      accountId: acc,
      holdingId: Value(fundId),
      cashTargetId: Value(cashId),
      type: TransactionType.sell.storageName,
      quantity: const Value(50),
      price: const Value(2.6),
      amount: 130,
      currency: const Value('CNY'),
      occurredAt: DateTime(2026, 9, 2),
      costMoved: const Value(false),
    ));

    final r = await run(DateTime(2026, 9, 10));
    expect(r.ok, isTrue);

    // 9-01：150 份 × 2.6 = 390（旧行为按当前 100 份 → 260）。
    final sep1 = (await dao.getSnapshots()).firstWhere((s) => s.date == '2026-09-01');
    expect(sep1.totalValue, closeTo(390, 1e-6));
    // 9-02：100 份 × 2.6 + 现金回款 130 = 390（连续）。
    final sep2 = (await dao.getSnapshots()).firstWhere((s) => s.date == '2026-09-02');
    expect(sep2.totalValue, closeTo(390, 1e-6));
  });

  test('v8 标记：老库升级后自动全量重建（覆盖锚点之前的旧口径快照）', () async {
    final acc = await dao.createAccount(
        AccountsCompanion.insert(name: 'a', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '现金',
      assetType: AssetType.cash.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(0),
      costPrice: const Value(0),
      latestPrice: const Value(1),
      purchaseDate: Value(DateTime(2026, 3, 1)),
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '基金',
      assetType: AssetType.mutualFund.storageName,
      marketSource: const Value('eastmoney'),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: const Value(2.6),
      purchaseDate: Value(DateTime(2026, 3, 1)),
    ));
    // 老版本 marker 已存在（v7 跑过），v8 marker 不存在 → 应全量重算。
    await dao.setSetting(
        'backfill_v7_gold_spot_and_today', '${DateTime(2026, 1, 1).millisecondsSinceEpoch}');
    await dao.setSetting('backfill_last_run', '2026-08-01');

    final r = await run(DateTime(2026, 9, 10));
    expect(r.ok, isTrue);

    // 8-31（早于 lastRun 锚点）也被重建覆盖。
    final s = await dao.getSnapshot('2026-08-31', 'CNY');
    expect(s, isNotNull);
    expect(s!.totalValue, closeTo(260, 1e-6));
    // 标记已写入，下次 light run 恢复正常窗口。
    expect(await dao.getSetting('backfill_v8_share_replay'), isNotNull);
  });
}