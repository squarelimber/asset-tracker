import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';

import 'package:asset_tracker/app/app.dart';
import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/router.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:asset_tracker/ui/components/sparkline.dart';
import 'package:asset_tracker/ui/pages/calendar/product_earnings_calendar_page.dart';
import 'package:asset_tracker/ui/pages/holdings/holding_kline_page.dart';

/// A product with one baseline day and one profit day per month of [year],
/// so every month has data (days = 2) and a deterministic rate. The value
/// carries over between months (it never resets), so each month's profit is
/// exactly [monthlyProfits][m-1] and the yearly rates stay distinct.
ProductEarnings _product(String name, List<double> monthlyProfits, int year) {
  final daily = <({String date, double value, double cost})>[];
  var value = 10000.0;
  for (var m = 1; m <= 12; m++) {
    final mm = m.toString().padLeft(2, '0');
    daily.add((date: '$year-$mm-01', value: value, cost: 10000));
    value += monthlyProfits[m - 1];
    daily.add((date: '$year-$mm-15', value: value, cost: 10000));
  }
  return ProductEarnings(
    name: name,
    type: AssetType.mutualFund,
    closed: false,
    daily: daily,
  );
}

Future<void> _pump(
  WidgetTester tester,
  List<ProductEarnings> products, {
  int year = 2025,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final nowYear = DateTime.now().year;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      hideAmountsProvider.overrideWith((ref) => false),
      alertEventsProvider.overrideWith((ref) => Stream.value(<AlertEventRow>[])),
      // The page starts on the current year; keep it empty so the real
      // provider (and its DB access) is never evaluated. Sync overrides skip
      // the loading state (no infinite spinner for pumpAndSettle).
      if (nowYear != year)
        productEarningsProvider(nowYear).overrideWith((ref) => const []),
      productEarningsProvider(year).overrideWith((ref) => products),
    ],
    child: const MaterialApp(home: ProductEarningsCalendarPage()),
  ));
  await tester.pump();
}

void main() {
  testWidgets('privacy masks earnings in year and month views', (tester) async {
    final year = DateTime.now().year;
    await _pump(tester, [
      _product('产品甲', List.filled(12, 100), year),
    ], year: year);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductEarningsCalendarPage)),
    );
    expect(find.text('+${Formats.amountCompact(100)}'), findsWidgets);
    container.read(hideAmountsProvider.notifier).state = true;
    await tester.pump();
    expect(find.text('+${Formats.amountCompact(100)}'), findsNothing);
    expect(find.text('****'), findsWidgets);
    await tester.tap(find.text('月', findRichText: true).last);
    await tester.pumpAndSettle();
    expect(find.text('收益 ****'), findsOneWidget);
    container.read(hideAmountsProvider.notifier).state = false;
    await tester.pump();
    expect(find.text('收益 ${Formats.signedAmount(100)}'), findsOneWidget);
  });

  testWidgets('name column stays pinned while the grid scrolls horizontally',
      (tester) async {
    await _pump(tester, [
      _product('产品甲', [100, 200, 300, 400, 500, 600, 0, 0, 0, 0, 0, 0], 2025),
      _product('产品乙', [10, 20, 30, 40, 50, 60, 0, 0, 0, 0, 0, 0], 2025),
    ]);
    // Navigate to 2025 so the full 12-month window is shown.
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();

    final amount = '+${Formats.amountCompact(100)}';
    final name = find.text('产品甲');
    expect(name, findsOneWidget);
    final nameBefore = tester.getTopLeft(name);
    final headerBefore = tester.getTopLeft(find.text('1月'));
    final cellBefore = tester.getTopLeft(find.text(amount));

    final gridScroll = find
        .ancestor(of: find.text(amount), matching: find.byType(SingleChildScrollView))
        .first;
    await tester.drag(gridScroll, const Offset(-200, 0));
    await tester.pumpAndSettle();

    // The product name did not move.
    expect(tester.getTopLeft(name), nameBefore);
    // The grid scrolled left ...
    final cellAfter = tester.getTopLeft(find.text(amount));
    expect(cellAfter.dx, lessThan(cellBefore.dx - 100));
    // ... and the month header followed it.
    final headerAfter = tester.getTopLeft(find.text('1月'));
    expect(headerAfter.dx, lessThan(headerBefore.dx - 100));
  });

  testWidgets('month header stays pinned while rows scroll vertically',
      (tester) async {
    // Distinct yearly rates keep the row order deterministic (desc).
    final products = List.generate(
      25,
      (i) => _product('产品${i + 1}', [
        100 * (i + 1),
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0
      ], 2025),
    );
    await _pump(tester, products);
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();

    final headerBefore = tester.getTopLeft(find.text('1月'));
    final firstRow = find.text('产品25');
    expect(firstRow, findsOneWidget);
    final firstRowBefore = tester.getTopLeft(firstRow);
    expect(firstRowBefore.dy, greaterThan(headerBefore.dy));

    final vScroll =
        find.ancestor(of: firstRow, matching: find.byType(CustomScrollView)).first;
    final vTopLeft = tester.getTopLeft(vScroll);
    await tester.dragFrom(
      vTopLeft + const Offset(40, 30),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();

    // The header stayed put ...
    expect(tester.getTopLeft(find.text('1月')), headerBefore);
    // ... while the rows scrolled up.
    final firstRowAfter = tester.getTopLeft(firstRow);
    expect(firstRowAfter.dy, lessThan(firstRowBefore.dy - 100));
  });

  testWidgets('month header follows the grid but is not independently scrollable',
      (tester) async {
    await _pump(tester, [
      _product('产品甲', [100, 200, 300, 400, 500, 600, 0, 0, 0, 0, 0, 0], 2025),
    ]);
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();

    final amount = '+${Formats.amountCompact(100)}';
    final cellBefore = tester.getTopLeft(find.text(amount));
    final headerTransform = find
        .ancestor(of: find.text('1月'), matching: find.byType(Transform))
        .first;
    await tester.drag(headerTransform, const Offset(-150, 0));
    await tester.pumpAndSettle();

    final cellAfter = tester.getTopLeft(find.text(amount));
    expect(cellAfter, cellBefore);
  });

  testWidgets('month view lists each product with its sparkline', (tester) async {
    await _pump(tester, [
      _product('产品甲', [100, 200, 300, 400, 500, 600, 0, 0, 0, 0, 0, 0], 2025),
      _product('产品乙', [10, 20, 30, 40, 50, 60, 0, 0, 0, 0, 0, 0], 2025),
    ]);
    await tester.tap(find.byTooltip('上一年'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('月', findRichText: true).last);
    await tester.pumpAndSettle();

    expect(find.text('产品甲'), findsOneWidget);
    expect(find.text('产品乙'), findsOneWidget);
    expect(find.byType(Sparkline), findsNWidgets(2));
  });

  testWidgets('annual and monthly rows open the exact grouped holdings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    final ids = <int>[];
    for (final (name, amount) in [
      ('账户甲', 100.0),
      ('账户乙', 200.0),
      ('另一个账户', 300.0),
    ]) {
      final account = await dao.createAccount(
        AccountsCompanion.insert(name: name, type: 'general'),
      );
      ids.add(
        await dao.createHolding(
          HoldingsCompanion.insert(
            accountId: account,
            name: '同名产品',
            assetType: 'savings',
            quantity: Value(amount),
          ),
        ),
      );
    }
    final year = DateTime.now().year;
    final product = _product('同名产品', List.filled(12, 100), year);
      final accounts = await dao.getAccounts();
      final holdings = await dao.getHoldings();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
          accountsProvider.overrideWith((ref) => Stream.value(accounts)),
          holdingsProvider.overrideWith((ref) => Stream.value(holdings)),
          priceCacheProvider.overrideWith((ref) async => {}),
          alertEventsProvider.overrideWith((ref) => Stream.value([])),
          for (final id in ids)
            transactionsByHoldingProvider(id).overrideWith((ref) => Stream.value([])),
        hideAmountsProvider.overrideWith((ref) => false),
        productEarningsProvider(year).overrideWith(
          (ref) => [
            ProductEarnings(
              name: product.name,
              type: product.type,
              closed: false,
              daily: product.daily,
              holdingIds: ids.take(2).toList(),
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    final router = container.read(routerProvider)..go('/product-earnings');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const AssetTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();

    for (final monthView in [false, true]) {
      if (monthView) {
        await tester.tap(find.text('月', findRichText: true).last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('同名产品'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/holdings/product');
      expect(find.byType(HoldingKlinePage), findsOneWidget);
      expect(find.text('账户甲'), findsOneWidget);
      expect(find.text('账户乙'), findsOneWidget);
      expect(find.text('另一个账户'), findsNothing);
      await tester.tap(find.text('账户乙'));
      await tester.pumpAndSettle();
      expect(find.text(Formats.money(200)), findsWidgets);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ProductEarningsCalendarPage), findsOneWidget);
    }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
  });
}
