import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/history_sync.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/daily_earnings.dart';
import 'package:asset_tracker/domain/category_earnings.dart';
import 'package:asset_tracker/domain/earnings_breakdown.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:asset_tracker/domain/range_stats.dart';
import 'package:asset_tracker/domain/rate_series.dart';
import 'package:asset_tracker/domain/transaction_service.dart';
import 'package:asset_tracker/services/history_backfill_service.dart';
import 'package:asset_tracker/services/market/history_source.dart';
import 'package:asset_tracker/services/snapshot_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedHistory extends HistoryDataSource {
  _FixedHistory() : super(MarketSource.eastmoney);

  @override
  Future<DailyPriceHistory> fetch(
    String symbol,
    DateTime from,
    DateTime to,
  ) async => {'2026-07-06': 10, '2026-07-07': 11, '2026-07-08': 12};
}

void main() {
  late AppDatabase db;
  late AssetDao dao;
  late TransactionService trades;
  late int account;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
    trades = TransactionService(dao);
    account = await dao.createAccount(
      AccountsCompanion.insert(name: '测试账户', type: 'general'),
    );
  });
  tearDown(() => db.close());

  Future<int> cash(double value, double cost) => dao.createHolding(
    HoldingsCompanion.insert(
      accountId: account,
      name: '现金',
      assetType: AssetType.cash.storageName,
      quantity: Value(value),
      costPrice: Value(cost),
      costRecorded: const Value(true),
      purchaseDate: Value(DateTime(2026, 7, 6)),
    ),
  );
  Future<int> fund({double latest = 12}) => dao.createHolding(
    HoldingsCompanion.insert(
      accountId: account,
      name: '基金',
      assetType: 'mutual_fund',
      marketSource: const Value('eastmoney'),
      symbol: const Value('110022'),
      quantity: const Value(100),
      costPrice: const Value(10),
      latestPrice: Value(latest),
      purchaseDate: Value(DateTime(2026, 7, 6)),
    ),
  );
  Future<void> snapshot(int day) => SnapshotService(
    dao,
    clock: () => DateTime(2026, 7, day, 16),
  ).ensureTodaySnapshot(force: true);
  Future<List<DailyEarning>> earnings() async =>
      const DailyEarningsCalculator().compute(await dao.getSnapshots());
  Future<void> stampFlows(int day) => db
      .update(db.transactions)
      .write(
        TransactionsCompanion(
          updatedAt: Value(DateTime(2026, 7, day, 12)),
          ledgerUpdatedAt: const Value(null),
        ),
      )
      .then((_) {});
  Future<void> expectAllViews(double expected) async {
    final snapshots = (await dao.getSnapshots())
      ..sort((a, b) => a.date.compareTo(b.date));
    final transactions = await dao.getTransactions();
    final daily = const DailyEarningsCalculator().compute(snapshots);
    expect(
      daily.fold(0.0, (sum, day) => sum + day.intervalProfit),
      closeTo(expected, 1e-8),
    );
    final breakdown = earningsBreakdownOf(
      snapshots,
      snapshots.last.date,
      transactions: transactions,
    );
    expect(breakdown.verified, isTrue, reason: breakdown.issue);
    expect(breakdown.detailTotal, closeTo(daily.last.intervalProfit, 1e-8));
    final products = productsFromSnapshots(
      snapshots,
      transactions: transactions,
    );
    const calculator = ProductEarningsCalculator();
    expect(
      products.fold(
        0.0,
        (sum, product) => sum + calculator.monthOf(product, 2026, 7).profit,
      ),
      closeTo(expected, 1e-8),
    );
    final categories = categoryEarningsOf(
      snapshots,
      holdings: await dao.getHoldings(),
      transactions: transactions,
      from: snapshots.first.date,
      to: snapshots.last.date,
    );
    expect(
      categories.verified,
      isTrue,
      reason: categories.issues.map((issue) => issue.message).join('; '),
    );
    expect(categories.totalProfit, closeTo(expected, 1e-8));
    expect(
      categories.categories.fold(0.0, (sum, category) => sum + category.profit),
      closeTo(expected, 1e-8),
    );
    expect(
      const RangeStatsCalculator().compute(snapshots)!.profit,
      closeTo(expected, 1e-8),
    );
    expect(
      const RateSeriesCalculator().ratesOf(snapshots).last,
      closeTo(expected / snapshotAssets(snapshots.first) * 100, 1e-8),
    );
  }

  test(
    'backfill preserves market earnings on a day with an external buy',
    () async {
      final id = await fund();
      final bought = await trades.record(
        accountId: account,
        holdingId: id,
        type: TransactionType.buy,
        quantity: 20,
        price: 11,
        amount: 220,
        occurredAt: DateTime(2026, 7, 7, 12),
      );
      expect(bought.ok, isTrue, reason: bought.message);
      await stampFlows(7);
      final rebuilt = await HistoryBackfillService(
        dao,
        sources: {MarketSource.eastmoney: _FixedHistory()},
      ).backfill(now: DateTime(2026, 7, 8, 16));
      expect(rebuilt.ok, isTrue, reason: rebuilt.message);
      final rows = await dao.getSnapshots();
      expect(rows.map((row) => row.date), [
        '2026-07-06',
        '2026-07-07',
        '2026-07-08',
      ]);
      final tradeDay = rows[1];
      expect(tradeDay.totalValue, closeTo(1320, 1e-8));
      expect(tradeDay.totalCost, closeTo(1220, 1e-8));
      expect((await earnings())[1].profit, closeTo(100, 1e-8));
      expect(snapshotHoldingValues(tradeDay), isNotNull);
    },
  );

  test(
    'new cash principal does not suppress the same day market gain',
    () async {
      final id = await fund(latest: 10);
      final target = await cash(100, 100);
      await snapshot(6);
      final deposited = await trades.record(
        accountId: account,
        type: TransactionType.income,
        amount: 500,
        cashTargetId: target,
        occurredAt: DateTime(2026, 7, 7, 12),
      );
      expect(deposited.ok, isTrue, reason: deposited.message);
      await stampFlows(7);
      await dao.updateHoldingPrice(id, 10.2);
      await snapshot(7);
      expect((await earnings()).last.profit, closeTo(20, 1e-8));
      await expectAllViews(20);
    },
  );

  test(
    'cash withdrawal carries earned gain out without creating a calendar loss',
    () async {
      final target = await cash(120, 100);
      await snapshot(6);
      final withdrawn = await trades.record(
        accountId: account,
        type: TransactionType.expense,
        amount: 60,
        cashTargetId: target,
        occurredAt: DateTime(2026, 7, 7, 12),
      );
      expect(withdrawn.ok, isTrue, reason: withdrawn.message);
      await stampFlows(7);
      await snapshot(7);
      expect((await dao.getHolding(target))!.quantity, 60);
      expect((await dao.getHolding(target))!.costPrice, 50);
      expect((await earnings()).last.profit, closeTo(0, 1e-8));
      expect(
        (await dao.getSnapshot('2026-07-07', 'CNY'))!.profitAdjustment,
        10,
      );
      await expectAllViews(0);
      await snapshot(7);
      expect(
        (await dao.getSnapshot('2026-07-07', 'CNY'))!.profitAdjustment,
        10,
      );
      await snapshot(8);
      expect((await earnings()).last.profit, closeTo(0, 1e-8));
      expect(
        (await dao.getSnapshot('2026-07-08', 'CNY'))!.profitAdjustment,
        10,
      );
      await expectAllViews(0);
    },
  );

  test(
    'an ex-dividend payout is counted once across the security and cash',
    () async {
      final id = await fund();
      final target = await cash(100, 100);
      await snapshot(6);
      final paid = await trades.record(
        accountId: account,
        holdingId: id,
        type: TransactionType.dividend,
        amount: 100,
        cashTargetId: target,
        occurredAt: DateTime(2026, 7, 7, 12),
      );
      expect(paid.ok, isTrue, reason: paid.message);
      await stampFlows(7);
      await dao.updateHoldingPrice(id, 11);
      await snapshot(7);
      final snapshots = await dao.getSnapshots();
      expect(snapshots.last.totalValue, snapshots.first.totalValue);
      expect((await earnings()).last.profit, closeTo(0, 1e-8));
      expect(snapshots.last.profitAdjustment, -100);
      await snapshot(7);
      expect(
        (await dao.getSnapshot('2026-07-07', 'CNY'))!.profitAdjustment,
        -100,
      );
      await expectAllViews(0);
    },
  );

  test(
    'withdrawing a cash loss preserves it without inventing a profit',
    () async {
      final target = await cash(80, 100);
      await snapshot(6);
      final withdrawn = await trades.record(
        accountId: account,
        type: TransactionType.expense,
        amount: 40,
        cashTargetId: target,
        occurredAt: DateTime(2026, 7, 7, 12),
      );
      expect(withdrawn.ok, isTrue, reason: withdrawn.message);
      await stampFlows(7);
      await snapshot(7);
      expect(
        (await dao.getSnapshot('2026-07-07', 'CNY'))!.profitAdjustment,
        -10,
      );
      await expectAllViews(0);
    },
  );

  test(
    'repaying debt preserves carried cash gain and excludes the debt principal',
    () async {
      final source = await cash(120, 100);
      final debt = await dao.createHolding(
        HoldingsCompanion.insert(
          accountId: account,
          name: '信用卡',
          assetType: 'liability',
          quantity: const Value(60),
          latestPrice: const Value(1),
          purchaseDate: Value(DateTime(2026, 7, 6)),
        ),
      );
      await snapshot(6);
      final repaid = await trades.record(
        accountId: account,
        type: TransactionType.transferOut,
        amount: 60,
        cashSourceId: source,
        cashTargetId: debt,
        occurredAt: DateTime(2026, 7, 7, 12),
      );
      expect(repaid.ok, isTrue, reason: repaid.message);
      await stampFlows(7);
      await snapshot(7);
      expect(
        (await dao.getSnapshot('2026-07-07', 'CNY'))!.profitAdjustment,
        10,
      );
      await expectAllViews(0);
    },
  );

  test(
    'internal cash transfer preserves total gain without a second correction',
    () async {
      final source = await cash(120, 100);
      final target = await cash(0, 0);
      await snapshot(6);
      final transferred = await trades.record(
        accountId: account,
        type: TransactionType.transferOut,
        amount: 60,
        cashSourceId: source,
        cashTargetId: target,
        occurredAt: DateTime(2026, 7, 7, 12),
      );
      expect(transferred.ok, isTrue, reason: transferred.message);
      await stampFlows(7);
      await snapshot(7);
      expect((await dao.getSnapshot('2026-07-07', 'CNY'))!.profitAdjustment, 0);
      await expectAllViews(0);
    },
  );

  test('an unlinked cash dividend remains genuine investment income', () async {
    final target = await cash(100, 100);
    await snapshot(6);
    final paid = await trades.record(
      accountId: account,
      type: TransactionType.dividend,
      amount: 100,
      cashTargetId: target,
      occurredAt: DateTime(2026, 7, 7, 12),
    );
    expect(paid.ok, isTrue, reason: paid.message);
    await stampFlows(7);
    await snapshot(7);
    expect((await dao.getSnapshot('2026-07-07', 'CNY'))!.profitAdjustment, 0);
    await expectAllViews(100);
  });

  test(
    'unverifiable cash principal never overwrites a corrected snapshot',
    () async {
      final target = await cash(120, 100);
      await snapshot(6);
      expect(
        (await trades.record(
          accountId: account,
          type: TransactionType.expense,
          amount: 60,
          cashTargetId: target,
          occurredAt: DateTime(2026, 7, 7, 12),
        )).ok,
        isTrue,
      );
      await stampFlows(7);
      await snapshot(7);
      final recorded = await dao.getSnapshot('2026-07-07', 'CNY');
      await db
          .update(db.transactions)
          .write(const TransactionsCompanion(costMovedAmount: Value(null)));
      await snapshot(7);
      expect(await dao.getSnapshot('2026-07-07', 'CNY'), recorded);
    },
  );

  test(
    'failed adjustment preserves snapshots, dirty flags and the rebuild marker',
    () async {
      final target = await cash(120, 100);
      await snapshot(6);
      expect(
        (await trades.record(
          accountId: account,
          type: TransactionType.expense,
          amount: 60,
          cashTargetId: target,
          occurredAt: DateTime(2026, 7, 7, 12),
        )).ok,
        isTrue,
      );
      await stampFlows(7);
      await db
          .update(db.transactions)
          .write(const TransactionsCompanion(costMovedAmount: Value(null)));
      await dao.setSetting(historySyncDirtyKey, historyDirtySet);
      await dao.setSetting(historyFullRebuildKey, '1');
      final original = await dao.getSnapshots();
      final result = await HistoryBackfillService(
        dao,
        sources: {},
      ).backfill(now: DateTime(2026, 7, 8, 16));
      expect(result.ok, isFalse);
      expect(result.historyUnavailable, isTrue);
      expect(result.message, contains('本金'));
      expect(await dao.getSnapshots(), original);
      expect(await dao.getSetting(historySyncDirtyKey), historyDirtySet);
      expect(await dao.getSetting(historyFullRebuildKey), '1');
      expect(
        await dao.getSetting('backfill_v15_cash_flow_profit_adjustments'),
        isNull,
      );
      expect(
        await dao.getSetting('backfill_v16_legacy_principal_and_cost_basis'),
        isNull,
      );
    },
  );
}
