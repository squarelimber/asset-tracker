import 'dart:async';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/earnings_breakdown.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SnapshotRow _snapshot(
  String date,
  double cash,
  double cashCost,
  double fund,
  double fundCost,
) {
  final holdings = [
    DayHoldingValue(
      holdingId: 1,
      name: '现金',
      type: AssetType.cash,
      value: cash,
      cost: cashCost,
      liability: false,
    ),
    DayHoldingValue(
      holdingId: 2,
      name: 'ETF',
      type: AssetType.etf,
      value: fund,
      cost: fundCost,
      liability: false,
    ),
  ];
  return SnapshotRow(
    date: date,
    currency: 'CNY',
    totalValue: cash + fund,
    totalCost: cashCost + fundCost,
    liabilities: 0,
    holdingValues: encodeHoldingValues(holdings),
    createdAt: DateTime(2026),
  );
}

void main() {
  test(
    'old incomplete attribution does not block next year baseline',
    () async {
      final snapshots = [
        _snapshot('2025-11-15', 10000, 8148, 3000, 3500),
        _snapshot('2025-11-17', 5397.7, 4398, 7595.4, 7250),
        _snapshot('2025-12-31', 5397.7, 4398, 7595.4, 7250),
        _snapshot('2026-01-02', 5397.7, 4398, 7605.4, 7250),
      ];
      final incomplete = TransactionRow(
        id: 1,
        accountId: 1,
        holdingId: 2,
        cashSourceId: 1,
        type: 'buy',
        amount: 4602.3,
        currency: 'CNY',
        occurredAt: DateTime(2025, 11, 16),
        costMoved: true,
        internalMove: false,
        updatedAt: DateTime(2026),
      );
      expect(
        () => productsFromSnapshots(snapshots, transactions: [incomplete]),
        throwsStateError,
      );
      final container = ProviderContainer(
        overrides: [
          historySyncProvider.overrideWith((ref) => null),
          snapshotsProvider.overrideWith((ref) => Stream.value(snapshots)),
          transactionsProvider.overrideWith(
            (ref) => Stream.value([incomplete]),
          ),
        ],
      );
      addTearDown(container.dispose);
      final nextYear = productEarningsProvider(2026);
      final currentSubscription = container.listen(nextYear, (_, _) {});
      addTearDown(currentSubscription.close);
      final products = await container.read(nextYear.future);
      final fund = products.singleWhere((p) => p.name == 'ETF');
      expect(
        const ProductEarningsCalculator().monthOf(fund, 2026, 1).profit,
        closeTo(10, 1e-8),
      );
      final previousYear = productEarningsProvider(2025);
      final pastSubscription = container.listen(previousYear, (_, _) {});
      addTearDown(pastSubscription.close);
      await expectLater(container.read(previousYear.future), throwsStateError);

      final crossing = incomplete.copyWith(occurredAt: DateTime(2026, 1, 1));
      expect(
        () => productsFromSnapshots(
          snapshots,
          transactions: [crossing],
          attributionRequiredFrom: '2026-01-01',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'zero transferred gain requires neither counterpart nor FX, but stale and unmatched nonzero legs fail',
    () {
      final snapshots = [
        _snapshot('2026-11-15', 600, 500, 200, 200),
        _snapshot('2026-11-17', 480, 380, 320, 320),
      ];
      TransactionRow movement({
        required int id,
        String type = 'buy',
        int holding = 2,
        int? source,
        double moved = 120,
        bool internal = false,
        String currency = 'CNY',
        DateTime? updated,
      }) => TransactionRow(
        id: id,
        accountId: 1,
        holdingId: holding,
        cashSourceId: source,
        type: type,
        amount: 120,
        currency: currency,
        occurredAt: DateTime(2026, 11, 16),
        costMoved: true,
        costMovedAmount: moved,
        internalMove: internal,
        updatedAt: updated ?? DateTime(2026),
      );
      for (final movementRow in [
        movement(id: 1, source: 3),
        movement(id: 2, source: 1, currency: 'USD'),
        movement(id: 3, type: 'sell', holding: 1, internal: true),
      ]) {
        expect(
          earningsBreakdownOf(
            snapshots,
            '2026-11-17',
            transactions: [movementRow],
          ).verified,
          isTrue,
        );
        expect(
          () => productsFromSnapshots(snapshots, transactions: [movementRow]),
          returnsNormally,
        );
      }
      final stale = movement(id: 4, source: 1, updated: DateTime(2026, 12));
      expect(
        earningsBreakdownOf(
          snapshots,
          '2026-11-17',
          transactions: [stale],
        ).verified,
        isFalse,
      );
      expect(
        () => productsFromSnapshots(snapshots, transactions: [stale]),
        throwsStateError,
      );
      final unequalPair = [
        movement(id: 5, type: 'sell', holding: 1, internal: true),
        movement(id: 6, type: 'buy', holding: 2, moved: 119, internal: true),
      ];
      expect(
        earningsBreakdownOf(
          snapshots,
          '2026-11-17',
          transactions: unequalPair,
        ).verified,
        isFalse,
      );
      expect(
        () => productsFromSnapshots(snapshots, transactions: unequalPair),
        throwsStateError,
      );
    },
  );

  test(
    'transaction updates refresh both daily and monthly attribution',
    () async {
      final snapshots = [
        _snapshot('2026-11-15', 10000, 8148, 3000, 3500),
        _snapshot('2026-11-17', 5397.7, 4398, 7595.4, 7250),
      ];
      final transactions = StreamController<List<TransactionRow>>();
      final container = ProviderContainer(
        overrides: [
          historySyncProvider.overrideWith((ref) => null),
          snapshotsProvider.overrideWith((ref) => Stream.value(snapshots)),
          transactionsProvider.overrideWith((ref) => transactions.stream),
        ],
      );
      final daily = earningsBreakdownProvider(DateTime(2026, 11, 17));
      final monthly = productEarningsProvider(2026);
      final dailySubscription = container.listen(daily, (_, _) {});
      final monthlySubscription = container.listen(monthly, (_, _) {});
      addTearDown(() async {
        dailySubscription.close();
        monthlySubscription.close();
        container.dispose();
        await transactions.close();
      });

      double dailyFund() => container
          .read(daily)
          .requireValue
          .rows
          .singleWhere((row) => row.name == 'ETF')
          .profit;
      double monthlyFund() => const ProductEarningsCalculator()
          .monthOf(
            container
                .read(monthly)
                .requireValue
                .singleWhere((p) => p.name == 'ETF'),
            2026,
            11,
          )
          .profit;

      transactions.add([]);
      await container.read(daily.future);
      await container.read(monthly.future);
      expect(dailyFund(), closeTo(845.4, 1e-8));
      expect(monthlyFund(), closeTo(845.4, 1e-8));

      transactions.add([
        TransactionRow(
          id: 1,
          accountId: 1,
          holdingId: 2,
          cashSourceId: 1,
          type: 'buy',
          quantity: 2300,
          price: 2.001,
          amount: 4602.3,
          currency: 'CNY',
          occurredAt: DateTime(2026, 11, 16),
          costMoved: true,
          costMovedAmount: 3750,
          internalMove: false,
          updatedAt: DateTime(2026),
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      await container.read(daily.future);
      await container.read(monthly.future);
      expect(dailyFund(), closeTo(-6.9, 1e-8));
      expect(monthlyFund(), closeTo(-6.9, 1e-8));
    },
  );
}
