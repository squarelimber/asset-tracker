import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/domain/risk_metrics.dart';
import 'package:asset_tracker/services/history_backfill_service.dart';
import 'package:asset_tracker/services/snapshot_service.dart';
import 'package:asset_tracker/services/market/history_source.dart';

class _History extends HistoryDataSource {
  _History() : super(MarketSource.sina);
  @override
  Future<DailyPriceHistory> fetch(
    String symbol,
    DateTime from,
    DateTime to,
  ) async => {'2026-06-30': 3, '2026-07-01': 3, '2026-07-02': 3};
}

void main() {
  test(
    'rebuild and forced refresh retain recorded buy cost despite a different holding unit cost',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = AssetDao(db);
      final account = await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'),
      );
      final cash = await dao.createHolding(
        HoldingsCompanion.insert(
          accountId: account,
          name: '现金',
          assetType: AssetType.cash.storageName,
          quantity: const Value(80),
          costPrice: const Value(80),
          costRecorded: const Value(true),
          purchaseDate: Value(DateTime(2026, 6, 30)),
        ),
      );
      final stock = await dao.createHolding(
        HoldingsCompanion.insert(
          accountId: account,
          name: 'ETF',
          assetType: AssetType.etf.storageName,
          marketSource: Value(MarketSource.sina.storageName),
          symbol: const Value('sh510000'),
          quantity: const Value(10),
          costPrice: const Value(2.1),
          latestPrice: const Value(3),
          purchaseDate: Value(DateTime(2026, 7, 1)),
        ),
      );
      await dao.createTransaction(
        TransactionsCompanion.insert(
          accountId: account,
          holdingId: Value(stock),
          cashSourceId: Value(cash),
          type: 'buy',
          quantity: const Value(10),
          price: const Value(2),
          amount: 20,
          costMovedAmount: const Value(20),
          occurredAt: DateTime(2026, 7, 1, 12),
          updatedAt: Value(DateTime(2026, 7, 1, 12)),
        ),
      );
      final holdings = await dao.getHoldings();
      final transactions = await dao.getTransactions();
      // Upgrade a v15 device with a light-run anchor. A day before that
      // anchor must be revisited when the v16 marker has not been written.
      for (final marker in [
        'backfill_v7_gold_spot_and_today',
        'backfill_v8_share_replay',
        'backfill_v9_smooth_share_replay',
        'backfill_v10_sina_history_endpoint',
        'backfill_v11_tencent_history_gateway',
        'backfill_v12_recorded_holding_values',
        'backfill_v13_transaction_replay',
        'backfill_v14_manual_nav_and_realized',
        'backfill_v15_cash_flow_profit_adjustments',
      ]) {
        await dao.setSetting(marker, '1');
      }
      await dao.setSetting('backfill_last_run', '2026-07-02');
      await dao.upsertSnapshot(
        SnapshotsCompanion.insert(
          date: '2026-06-30',
          totalValue: 999,
          totalCost: 100,
        ),
      );
      final result = await HistoryBackfillService(
        dao,
        sources: {MarketSource.sina: _History()},
      ).backfill(now: DateTime(2026, 7, 2, 16));
      expect(result.ok, isTrue, reason: result.message);
      expect((await dao.getSnapshot('2026-06-30', 'CNY'))!.totalValue, 100);
      expect(
        await dao.getSetting('backfill_v16_legacy_principal_and_cost_basis'),
        isNotNull,
      );
      final before = (await dao.getSnapshot('2026-07-02', 'CNY'))!;
      expect(before.totalCost, 100);
      final initialRisk = estimateRiskMetrics(
        await dao.getSnapshots(),
        transactions,
        annualRiskFreeRate: 0.01,
        now: DateTime(2026, 7, 3),
      );
      expect(initialRisk.sampleCount, 2);
      expect(initialRisk.interruptionReason, isNull);
      var now = DateTime(2026, 7, 2, 18);
      final service = SnapshotService(dao, clock: () => now);
      for (var i = 0; i < 2; i++) {
        await service.ensureTodaySnapshot(force: true);
        final current = (await dao.getSnapshot('2026-07-02', 'CNY'))!;
        expect(current.totalCost, before.totalCost);
        expect(current.totalValue, before.totalValue);
        expect(
          snapshotHoldingValues(
            current,
          )!.singleWhere((v) => v.holdingId == stock).cost,
          20,
        );
        expect(await dao.getHoldings(), holdings);
        expect(await dao.getTransactions(), transactions);
        final risk = estimateRiskMetrics(
          await dao.getSnapshots(),
          transactions,
          annualRiskFreeRate: 0.01,
          now: DateTime(2026, 7, 3),
        );
        expect(risk.sampleCount, initialRisk.sampleCount);
        expect(risk.interruptionReason, isNull);
        now = now.add(const Duration(minutes: 1));
      }
      await dao.updateHolding(
        (await dao.getHolding(stock))!.copyWith(latestPrice: 3.2),
      );
      await service.ensureTodaySnapshot(force: true);
      final repriced = (await dao.getSnapshot('2026-07-02', 'CNY'))!;
      expect(repriced.totalValue, 112);
      expect(repriced.totalCost, 100);
      expect((await dao.getHolding(stock))!.costPrice, 2.1);
    },
  );

  test('a holding without trades keeps its manually recorded cost', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    final account = await dao.createAccount(
      AccountsCompanion.insert(name: '账户', type: 'general'),
    );
    await dao.createHolding(
      HoldingsCompanion.insert(
        accountId: account,
        name: 'ETF',
        assetType: AssetType.etf.storageName,
        quantity: const Value(10),
        costPrice: const Value(2.1),
        latestPrice: const Value(3),
      ),
    );
    await SnapshotService(
      dao,
      clock: () => DateTime(2026, 7, 2),
    ).ensureTodaySnapshot();
    expect((await dao.getSnapshots()).single.totalCost, 21);
  });
}
