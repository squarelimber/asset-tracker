import 'dart:async';

import 'package:asset_tracker/app/category_earnings_provider.dart';
import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/category_earnings.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _period = (from: '2026-11-01', to: '2026-11-30');
final _provider = categoryEarningsProvider(_period);

class _Fixture {
  _Fixture(
    this.db,
    this.dao,
    this.container,
    this.account,
    this.fund,
    this.cash,
  );

  final AppDatabase db;
  final AssetDao dao;
  final ProviderContainer container;
  final int account;
  final int fund;
  final int? cash;

  Future<void> snapshot(
    String date, {
    required double fundValue,
    double fundCost = 100,
    double cashValue = 0,
    double cashCost = 0,
  }) => dao.upsertSnapshot(
    SnapshotsCompanion.insert(
      date: date,
      totalValue: fundValue + cashValue,
      totalCost: fundCost + cashCost,
      createdAt: Value(DateTime(2026, 11, 20)),
      holdingValues: Value(
        encodeHoldingValues([
          if (cash != null)
            DayHoldingValue(
              holdingId: cash!,
              name: '现金',
              type: AssetType.cash,
              value: cashValue,
              cost: cashCost,
              liability: false,
            ),
          DayHoldingValue(
            holdingId: fund,
            name: 'ETF',
            type: AssetType.etf,
            value: fundValue,
            cost: fundCost,
            liability: false,
          ),
        ]),
      ),
    ),
  );

  Future<CategoryEarningsReport> nextReport(
    bool Function(CategoryEarningsReport report) matches,
  ) {
    final result = Completer<CategoryEarningsReport>();
    final subscription = container.listen(_provider, (_, value) {
      final report = value.asData?.value;
      if (!result.isCompleted && report != null && matches(report)) {
        result.complete(report);
      }
    });
    addTearDown(subscription.close);
    return result.future.timeout(const Duration(seconds: 5));
  }
}

Future<_Fixture> _fixture({bool withCash = false}) async {
  final db = AppDatabase(NativeDatabase.memory());
  final dao = AssetDao(db);
  final account = await dao.createAccount(
    AccountsCompanion.insert(name: '测试账户', type: 'general'),
  );
  final fund = await dao.createHolding(
    HoldingsCompanion.insert(
      accountId: account,
      name: 'ETF',
      assetType: 'etf',
      currency: const Value('USD'),
      quantity: const Value(10),
      costPrice: const Value(999),
      latestPrice: const Value(9999),
    ),
  );
  final cash = withCash
      ? await dao.createHolding(
          HoldingsCompanion.insert(
            accountId: account,
            name: '现金',
            assetType: AssetType.cash.storageName,
          ),
        )
      : null;
  var marketReads = 0;
  var rateReads = 0;
  var syncReads = 0;
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      marketServiceProvider.overrideWith((ref) {
        marketReads++;
        throw StateError('分类收益不应读取当前行情');
      }),
      cnyRatesProvider.overrideWith((ref) async {
        rateReads++;
        throw StateError('历史人民币收益不应读取当前汇率');
      }),
      historySyncProvider.overrideWith((ref) async {
        syncReads++;
        throw StateError('统计摘要不应触发历史同步');
      }),
    ],
  );
  addTearDown(() async {
    expect(marketReads, 0);
    expect(rateReads, 0);
    expect(syncReads, 0);
    container.dispose();
    await db.close();
  });
  return _Fixture(db, dao, container, account, fund, cash);
}

Future<CategoryEarningsReport> _start(_Fixture fixture) {
  final subscription = fixture.container.listen(_provider, (_, _) {});
  addTearDown(subscription.close);
  return fixture.container.read(_provider.future);
}

double _profit(CategoryEarningsReport report, AssetCategory category) =>
    report.categories.singleWhere((row) => row.category == category).profit;

void main() {
  test(
    'holding category edits regroup history without reading current quotes',
    () async {
      final fixture = await _fixture();
      await fixture.snapshot('2026-11-15', fundValue: 100);
      await fixture.snapshot('2026-11-16', fundValue: 110);
      final initial = await _start(fixture);
      expect(initial.verified, isTrue);
      expect(_profit(initial, AssetCategory.equity), 10);

      final next = fixture.nextReport(
        (report) =>
            report.categories.any((row) => row.category == AssetCategory.gold),
      );
      final holding = (await fixture.dao.getHolding(fixture.fund))!;
      await fixture.dao.updateHolding(
        holding.copyWith(categoryOverride: const Value('gold')),
      );
      final regrouped = await next;
      expect(regrouped.verified, isTrue);
      expect(regrouped.categories.single.category, AssetCategory.gold);
      expect(regrouped.totalProfit, 10);
      expect(regrouped.categories.single.products.single.holdingIds, [
        fixture.fund,
      ]);
      expect(regrouped.categories.single.rate, closeTo(0.1, 1e-10));
    },
  );

  test('snapshot edits refresh the historical amount and rate', () async {
    final fixture = await _fixture();
    await fixture.snapshot('2026-11-15', fundValue: 100);
    await fixture.snapshot('2026-11-16', fundValue: 110);
    expect((await _start(fixture)).totalProfit, 10);

    final next = fixture.nextReport((report) => report.totalProfit == 25);
    await fixture.snapshot('2026-11-16', fundValue: 125);
    final updated = await next;
    expect(updated.verified, isTrue);
    expect(updated.categories.single.profit, 25);
    expect(updated.categories.single.rate, closeTo(0.25, 1e-10));
    expect(updated.totalRate, closeTo(0.25, 1e-10));
  });

  test(
    'transaction stream changes reattribute carried gains and flag stale flows',
    () async {
      final fixture = await _fixture(withCash: true);
      await fixture.snapshot(
        '2026-11-15',
        fundValue: 100,
        cashValue: 120,
        cashCost: 100,
      );
      await fixture.snapshot(
        '2026-11-16',
        fundValue: 160,
        fundCost: 150,
        cashValue: 60,
        cashCost: 50,
      );
      final initial = await _start(fixture);
      expect(initial.verified, isTrue);
      expect(initial.totalProfit, 0);
      expect(_profit(initial, AssetCategory.cash), -10);
      expect(_profit(initial, AssetCategory.equity), 10);

      final moved = fixture.nextReport(
        (report) =>
            report.verified && _profit(report, AssetCategory.equity) == 0,
      );
      final transaction = await fixture.dao.createTransaction(
        TransactionsCompanion.insert(
          accountId: fixture.account,
          holdingId: Value(fixture.fund),
          cashSourceId: Value(fixture.cash),
          type: 'buy',
          amount: 60,
          costMovedAmount: const Value(50),
          occurredAt: DateTime(2026, 11, 16),
          updatedAt: Value(DateTime(2026, 11, 16)),
        ),
      );
      final corrected = await moved;
      expect(corrected.totalProfit, 0);
      expect(_profit(corrected, AssetCategory.cash), 0);

      final stale = fixture.nextReport((report) => !report.verified);
      final row = (await fixture.dao.getTransaction(transaction))!;
      await fixture.dao.updateTransaction(row, now: DateTime(2026, 11, 21));
      final affected = await stale;
      expect(affected.categories, isEmpty);
      expect(
        affected.issues.any((issue) => issue.transactionId == transaction),
        isTrue,
      );
    },
  );
}
