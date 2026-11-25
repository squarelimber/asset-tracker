import 'package:asset_tracker/app/app.dart';
import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/services/market/market_service.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_intraday.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_page.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_widgets.dart';
import 'package:asset_tracker/ui/pages/stats/category_earnings_page.dart';
import 'package:asset_tracker/ui/pages/stats/stats_page.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _NoMarket extends MarketService {
  _NoMarket(super.dao);

  @override
  Future<MarketRefreshResult> refreshAll() async =>
      MarketRefreshResult(updated: 0, failed: 0, fetchedAt: DateTime.now());
}

Future<void> _pumpNavigation(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _mountApp(WidgetTester tester, double width) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.reset);
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final dao = AssetDao(db);
  final account = await dao.createAccount(
    AccountsCompanion.insert(name: '测试账户', type: 'general'),
  );
  final holding = await dao.createHolding(
    HoldingsCompanion.insert(
      accountId: account,
      name: '黄金分类测试ETF',
      assetType: 'etf',
      categoryOverride: const Value('gold'),
      quantity: const Value(100),
      costPrice: const Value(10),
      latestPrice: const Value(11.1),
    ),
  );
  final today = DateUtils.dateOnly(DateTime.now());
  for (final day in [today.subtract(const Duration(days: 1)), today]) {
    final value = day == today ? 1110.0 : 1100.0;
    await dao.upsertSnapshot(
      SnapshotsCompanion.insert(
        date: Formats.date(day),
        totalValue: value,
        totalCost: 1000,
        holdingValues: Value(
          encodeHoldingValues([
            DayHoldingValue(
              holdingId: holding,
              name: '黄金分类测试ETF',
              type: AssetType.etf,
              value: value,
              cost: 1000,
              liability: false,
            ),
          ]),
        ),
      ),
    );
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        historySyncProvider.overrideWith((ref) async => null),
        tradingCalendarProvider.overrideWith((ref) async {}),
        marketServiceProvider.overrideWithValue(_NoMarket(dao)),
        portfolioIntradayProvider.overrideWith((ref, day) => Stream.value([])),
        portfolioIntradayHistoryProvider.overrideWith(
          (ref, day) async => (
            points: <({int minute, double profit})>[],
            covered: 0,
            eligible: 0,
          ),
        ),
        hideAmountsProvider.overrideWith((ref) => false),
      ],
      child: const AssetTrackerApp(),
    ),
  );
  await _pumpNavigation(tester);
}

void _expectAnalysisNavigationHidden() {
  expect(find.byType(NavigationBar), findsNothing);
  expect(find.text('资产管理'), findsNothing);
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'stats and allocation open category earnings and return to their source ($width)',
      (tester) async {
        await _mountApp(tester, width);

        await tester.tap(find.text('统计'));
        await _pumpNavigation(tester);
        expect(find.byType(StatsPage), findsOneWidget);
        await tester.tap(find.widgetWithText(OutlinedButton, '分类收益'));
        await _pumpNavigation(tester);
        expect(find.byType(CategoryEarningsPage), findsOneWidget);
        _expectAnalysisNavigationHidden();
        expect(find.text('黄金'), findsWidgets);
        expect(find.textContaining('10.00'), findsWidgets);
        await tester.tap(find.byTooltip('返回'));
        await _pumpNavigation(tester);
        expect(find.byType(StatsPage), findsOneWidget);

        final router = GoRouter.of(tester.element(find.byType(StatsPage)));
        router.go('/portfolio');
        await _pumpNavigation(tester);
        final shortcut = find.descendant(
          of: find.byType(AllocationCard),
          matching: find.text('查看收益'),
        );
        await tester.scrollUntilVisible(
          shortcut,
          250,
          scrollable: find
              .descendant(
                of: find.byType(PortfolioPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await _pumpNavigation(tester);
        await tester.ensureVisible(shortcut);
        await tester.pump();
        await tester.tap(shortcut.hitTestable());
        await _pumpNavigation(tester);
        expect(router.state.uri.path, '/category-earnings');
        _expectAnalysisNavigationHidden();
        await tester.binding.handlePopRoute();
        await _pumpNavigation(tester);
        expect(router.state.uri.path, '/portfolio');
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      },
    );

    testWidgets(
      'direct category link preserves classification, masks amounts and falls back to stats ($width)',
      (tester) async {
        await _mountApp(tester, width);
        final router = GoRouter.of(tester.element(find.byType(PortfolioPage)));
        router.go('/category-earnings?category=gold');
        await _pumpNavigation(tester);
        final page = find.byType(CategoryEarningsPage);
        expect(page, findsOneWidget);
        expect(
          tester.widget<CategoryEarningsPage>(page).initialCategory,
          AssetCategory.gold,
        );
        expect(find.text('黄金分类测试ETF'), findsOneWidget);
        _expectAnalysisNavigationHidden();
        final container = ProviderScope.containerOf(tester.element(page));
        container.read(hideAmountsProvider.notifier).state = true;
        await tester.pump();
        expect(find.textContaining('10.00'), findsNothing);
        expect(find.textContaining('0.91%'), findsNothing);
        await tester.tap(find.byTooltip('返回'));
        await _pumpNavigation(tester);
        expect(router.state.uri.path, '/stats');

        router.go('/category-earnings');
        await _pumpNavigation(tester);
        await tester.binding.handlePopRoute();
        await _pumpNavigation(tester);
        expect(router.state.uri.path, '/stats');
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      },
    );
  }
}
