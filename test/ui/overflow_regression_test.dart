import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/domain/trade_stats.dart';
import 'package:asset_tracker/services/market/global_quote_source.dart';
import 'package:asset_tracker/ui/pages/accounts/accounts_page.dart';
import 'package:asset_tracker/ui/pages/alerts/alerts_page.dart';
import 'package:asset_tracker/ui/pages/markets/markets_page.dart';
import 'package:asset_tracker/domain/daily_earnings.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:asset_tracker/ui/pages/calendar/earnings_calendar_page.dart';
import 'package:asset_tracker/ui/pages/calendar/product_earnings_calendar_page.dart';
import 'package:asset_tracker/ui/pages/settings/settings_page.dart';
import 'package:asset_tracker/ui/pages/stats/stats_page.dart';
import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [page] at a fixed logical size with an in-memory DB and bounded
/// pumps (no pumpAndSettle: pages may run repeating animations).
Future<void> pumpPage(
  WidgetTester tester,
  Widget page,
  Size size, {
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      historySyncProvider.overrideWith((ref) => null),
      ...overrides,
    ],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

/// Fails if a RenderFlex overflow was reported during the last pumps.
void expectNoOverflow(WidgetTester tester) {
  final e = tester.takeException();
  expect(e, isNull, reason: 'RenderFlex overflow');
}

void main() {
  testWidgets('smoke: empty scaffold', (tester) async {
    await pumpPage(tester, const Scaffold(body: Text('x')), const Size(360, 640));
    expectNoOverflow(tester);
  });

  testWidgets('portfolio no overflow at phone and desktop', (tester) async {
    final now = DateTime(2026, 8, 27);
    final snaps = List.generate(
      30,
      (i) => SnapshotRow(
        date: now.subtract(Duration(days: 29 - i)).toIso8601String().substring(0, 10),
        currency: 'CNY',
        totalValue: 100000 + i * 500,
        totalCost: 90000,
        liabilities: 10000,
        createdAt: now,
      ),
    );
    final holding = HoldingRow(
      id: 1,
      accountId: 1,
      name: '现金',
      assetType: 'savings',
      marketSource: 'manual',
      quantity: 100,
      costPrice: 900,
      latestPrice: 1000,
      currency: 'CNY',
      archived: false,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    const summary = PortfolioSummary(
      totalAssets: 100000,
      totalLiabilities: 10000,
      totalCost: 90000,
      todayChange: 500,
      todayChangePct: 0.005,
      breakdown: [
        TypeBreakdown(type: AssetType.cash, marketValue: 100000, cost: 90000),
      ],
    );
    final overrides = <Override>[
      summaryProvider.overrideWith((ref) => summary),
      holdingsProvider.overrideWith((ref) => Stream.value([holding])),
      snapshotsProvider.overrideWith((ref) => Stream.value(snaps)),
    ];
    await pumpPage(tester, const PortfolioPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const PortfolioPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });

  testWidgets('holdings no overflow at phone and desktop', (tester) async {
    final a = HoldingRow(
      id: 1,
      accountId: 1,
      name: '现金',
      assetType: 'savings',
      marketSource: 'manual',
      quantity: 100,
      costPrice: 900,
      latestPrice: 1000,
      currency: 'CNY',
      archived: false,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final b = HoldingRow(
      id: 2,
      accountId: 1,
      name: '某股票',
      assetType: 'stock',
      marketSource: 'manual',
      symbol: '600000',
      quantity: 1000,
      costPrice: 10,
      latestPrice: 12,
      currency: 'CNY',
      archived: false,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final c = HoldingRow(
      id: 3,
      accountId: 1,
      name: '信用卡',
      assetType: 'liability',
      marketSource: 'manual',
      quantity: 5000,
      costPrice: 0,
      latestPrice: 0,
      currency: 'CNY',
      archived: false,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final overrides = <Override>[
      holdingsProvider.overrideWith((ref) => Stream.value([a, b, c])),
    ];
    await pumpPage(tester, const HoldingsPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const HoldingsPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });

  testWidgets('accounts no overflow at phone and desktop', (tester) async {
    final account = AccountRow(
      id: 1,
      name: '测试账户',
      type: 'general',
      currency: 'CNY',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final overrides = <Override>[
      accountsProvider.overrideWith((ref) => Stream.value([account])),
      holdingsProvider.overrideWith((ref) => Stream.value(<HoldingRow>[])),
    ];
    await pumpPage(tester, const AccountsPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const AccountsPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });

  testWidgets('markets: no overflow', (tester) async {
    final overrides = <Override>[
      quotesProvider.overrideWith(
        (ref) => const [
          GlobalQuote(code: '000001', name: '上证指数', group: 'A股', price: 3200.5, change: 12.3, changePct: 0.0039),
          GlobalQuote(code: 'USD', name: '美元', group: '货币', price: 7.25, change: -0.01, changePct: -0.0014, fxSymbol: 'USD'),
        ],
      ),
    ];
    await pumpPage(tester, const MarketsPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const MarketsPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });

  testWidgets('stats: no overflow', (tester) async {
    final overrides = <Override>[
      statsProvider.overrideWith(
        (ref) => const TradeStats(
          boughtTotal: 100000,
          soldTotal: 20000,
          incomeTotal: 50000,
          expenseTotal: 12000,
          dividendTotal: 3000,
          realizedProfit: 8000,
          monthlyCashflow: {'2026-07': -12000, '2026-08': 5000},
        ),
      ),
    ];
    await pumpPage(tester, const StatsPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const StatsPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });

  testWidgets('alerts: no overflow', (tester) async {
    final overrides = <Override>[
      alertRulesProvider.overrideWith(
        (ref) => Stream.value([
          AlertRuleRow(
            id: 1,
            type: 'concentration',
            name: '集中度风险',
            params: '{"threshold":0.3}',
            enabled: true,
            createdAt: DateTime(2026, 8, 1),
            updatedAt: DateTime(2026, 8, 1),
          ),
        ]),
      ),
      alertEventsProvider.overrideWith(
        (ref) => Stream.value([
          AlertEventRow(
            id: 1,
            ruleId: 1,
            title: '集中度风险',
            message: '单笔持仓占比 42% 超过阈值',
            triggeredAt: DateTime(2026, 8, 20, 9, 30),
          ),
        ]),
      ),
    ];
    await pumpPage(tester, const AlertsPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const AlertsPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });

  testWidgets('settings: no overflow', (tester) async {
    await pumpPage(tester, const SettingsPage(), const Size(360, 640));
    expectNoOverflow(tester);
    await pumpPage(tester, const SettingsPage(), const Size(1280, 800));
    expectNoOverflow(tester);
  });

  testWidgets('earnings calendar no overflow at phone and desktop', (tester) async {
    final now = DateTime.now();
    final d1 = DateTime(now.year, now.month, 10);
    final d2 = DateTime(now.year, now.month, 11);
    final overrides = <Override>[
      earningsProvider.overrideWith((ref) => [
        DailyEarning(
          date: d1.toIso8601String().substring(0, 10),
          profit: 120,
          totalValue: 100000,
          totalCost: 99880,
          liabilities: 0,
        ),
        DailyEarning(
          date: d2.toIso8601String().substring(0, 10),
          profit: -80,
          totalValue: 99920,
          totalCost: 99880,
          liabilities: 0,
        ),
      ]),
      alertEventsProvider.overrideWith((ref) => Stream.value(<AlertEventRow>[])),
    ];
    await pumpPage(tester, const EarningsCalendarPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const EarningsCalendarPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
  });

  ProductEarnings pe(String name, double profit, int year) {
    final daily = <({String date, double value, double cost})>[];
    var value = 10000.0;
    for (var m = 1; m <= 12; m++) {
      final mm = m.toString().padLeft(2, '0');
      daily.add((date: '$year-$mm-01', value: value, cost: 10000));
      value += profit;
      daily.add((date: '$year-$mm-15', value: value, cost: 10000));
    }
    return ProductEarnings(
      name: name,
      type: AssetType.mutualFund,
      closed: false,
      daily: daily,
    );
  }

  testWidgets('product earnings calendar no overflow at phone and desktop', (tester) async {
    final now = DateTime.now();
    final products = [
      pe('产品甲', 100, now.year),
      pe('产品乙', -50, now.year),
    ];
    final overrides = <Override>[
      productEarningsProvider(now.year).overrideWith((ref) => products),
      alertEventsProvider.overrideWith((ref) => Stream.value(<AlertEventRow>[])),
    ];
    await pumpPage(tester, const ProductEarningsCalendarPage(), const Size(360, 640), overrides: overrides);
    expectNoOverflow(tester);
    await pumpPage(tester, const ProductEarningsCalendarPage(), const Size(1280, 800), overrides: overrides);
    expectNoOverflow(tester);
    // The page watches the autoDispose `productEarningsProvider`. Unmounting
    // the tree inside the test body (rather than letting the binding's
    // post-test `runApp` do it) lets us flush the Riverpod dispose timer with
    // a timed pump; the binding's final duration-less `pump()` never elapses,
    // so a timer scheduled during the post-test unmount would stay pending.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
