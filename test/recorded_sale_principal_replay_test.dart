import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:flutter_test/flutter_test.dart';

HoldingRow _holding() => HoldingRow(
  id: 1,
  accountId: 1,
  name: '测试持仓',
  assetType: 'etf',
  marketSource: 'sina',
  quantity: 80,
  costPrice: 2,
  costRecorded: true,
  latestPrice: 3,
  currency: 'CNY',
  archived: false,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 2),
);

TransactionRow _sale({required bool external, double? principal}) =>
    TransactionRow(
      id: 2,
      accountId: 1,
      holdingId: 1,
      cashTargetId: external ? null : 2,
      type: 'sell',
      quantity: 20,
      amount: 60,
      currency: 'CNY',
      costMoved: true,
      internalMove: false,
      costMovedAmount: external ? null : principal,
      externalSellPrincipal: external ? principal : null,
      occurredAt: DateTime(2026, 1, 2),
      updatedAt: DateTime(2026, 1, 2),
    );

void main() {
  for (final external in [false, true]) {
    for (final openingBuy in [false, true]) {
      test(
        'recorded partial-sale debit conserves cost: external=$external, openingBuy=$openingBuy',
        () {
          final captured = <int, double>{};
          final history = const HoldingReplay().replay(
            _holding(),
            [
              if (openingBuy)
                TransactionRow(
                  id: 1,
                  accountId: 1,
                  holdingId: 1,
                  type: 'buy',
                  quantity: 100,
                  amount: 210,
                  currency: 'CNY',
                  costMoved: false,
                  internalMove: false,
                  occurredAt: DateTime(2026, 1, 1),
                  updatedAt: DateTime(2026, 1, 1),
                ),
              _sale(external: external, principal: 50),
            ],
            from: DateTime(2026, 1, 1),
            to: DateTime(2026, 1, 3),
            capturedSellPrincipal: captured,
          );
          expect(history['2026-01-01']!.$1, 100);
          expect(history['2026-01-01']!.$2, closeTo(210, 1e-8));
          expect(history['2026-01-02']!.$1, 80);
          expect(history['2026-01-02']!.$2, closeTo(160, 1e-8));
          expect(history['2026-01-03']!.$2, closeTo(160, 1e-8));
          expect(captured[2], 50);
          expect(
            history['2026-01-01']!.$2 - history['2026-01-02']!.$2,
            captured[2],
          );
        },
      );
    }
  }
  test(
    'zero principal remains explicit and a missing principal retains average-cost behavior',
    () {
      for (final principal in <double?>[0, null]) {
        final captured = <int, double>{};
        final history = const HoldingReplay().replay(
          _holding(),
          [_sale(external: false, principal: principal)],
          from: DateTime(2026, 1, 1),
          to: DateTime(2026, 1, 2),
          capturedSellPrincipal: captured,
        );
        expect(history['2026-01-01']!.$2, principal == null ? 200 : 160);
        expect(history['2026-01-02']!.$2, 160);
        expect(captured[2], principal ?? 40);
      }
    },
  );
}
