import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'overflow_regression_test.dart' as helpers;

void main() {
  testWidgets('holdings sort by displayed unit cost and converted values', (
    tester,
  ) async {
    final now = DateTime(2026, 1, 1);
    final base = HoldingRow(
      id: 1,
      accountId: 1,
      name: '人民币持仓',
      assetType: 'stock',
      marketSource: 'manual',
      quantity: 100,
      costPrice: 10,
      latestPrice: 20,
      currency: 'CNY',
      archived: false,
      costRecorded: true,
      createdAt: now,
      updatedAt: now,
    );
    final dollar = base.copyWith(
      id: 2,
      name: '美元持仓',
      currency: 'USD',
      quantity: 10,
      costPrice: 30,
      latestPrice: 100,
    );
    final unknown = base.copyWith(
      id: 3,
      name: '缺汇率持仓',
      currency: 'HKD',
      quantity: 1000,
      costPrice: 1,
      latestPrice: 100,
    );
    await helpers.pumpPage(
      tester,
      const HoldingsPage(),
      const Size(1280, 800),
      overrides: [
        holdingsProvider.overrideWith(
          (_) => Stream.value([base, dollar, unknown]),
        ),
        cnyRatesProvider.overrideWith((_) async => {'USD': 7}),
      ],
    );
    double top(String name) => tester.getTopLeft(find.text(name)).dy;

    await tester.tap(find.text('成本单价'));
    await tester.pumpAndSettle();
    expect(top('美元持仓'), lessThan(top('人民币持仓')));
    expect(top('人民币持仓'), lessThan(top('缺汇率持仓')));

    await tester.tap(find.text('市值'));
    await tester.pumpAndSettle();
    expect(top('美元持仓'), lessThan(top('人民币持仓')));
    expect(top('人民币持仓'), lessThan(top('缺汇率持仓')));
    await tester.tap(find.text('市值'));
    await tester.pumpAndSettle();
    expect(top('人民币持仓'), lessThan(top('美元持仓')));
    expect(top('美元持仓'), lessThan(top('缺汇率持仓')));
  });

  testWidgets('closed holdings sort by displayed realized profit', (
    tester,
  ) async {
    final now = DateTime(2026, 1, 1);
    final open = HoldingRow(
      id: 1,
      accountId: 1,
      name: '持有中',
      assetType: 'stock',
      marketSource: 'manual',
      quantity: 10,
      costPrice: 10,
      latestPrice: 15,
      currency: 'CNY',
      archived: false,
      costRecorded: true,
      createdAt: now,
      updatedAt: now,
    );
    final closed = open.copyWith(id: 2, name: '已清仓', quantity: 0);
    final sell = TransactionRow(
      id: 1,
      accountId: 1,
      holdingId: 2,
      type: 'sell',
      quantity: 10,
      price: 30,
      amount: 300,
      currency: 'CNY',
      occurredAt: now,
      updatedAt: now,
      costMoved: false,
      internalMove: false,
    );
    await helpers.pumpPage(
      tester,
      const HoldingsPage(),
      const Size(1280, 800),
      overrides: [
        holdingsProvider.overrideWith((_) => Stream.value([open, closed])),
        transactionsByHoldingProvider.overrideWith(
          (_, id) => Stream.value(id == 2 ? [sell] : <TransactionRow>[]),
        ),
        cnyRatesProvider.overrideWith((_) async => {}),
      ],
    );
    await tester.tap(find.text('盈亏 / 收益率'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('已清仓')).dy,
      lessThan(tester.getTopLeft(find.text('持有中')).dy),
    );
  });
}
