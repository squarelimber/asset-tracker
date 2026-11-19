import 'package:asset_tracker/app/app.dart';
import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/services/market/market_service.dart';
import 'package:asset_tracker/ui/components/asset_overview_card.dart';
import 'package:asset_tracker/ui/components/intraday_line_chart.dart';
import 'package:asset_tracker/ui/pages/calendar/earnings_calendar_page.dart';
import 'package:asset_tracker/ui/pages/holdings/holding_kline_page.dart';
import 'package:asset_tracker/ui/pages/portfolio/day_detail_sheet.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_intraday.dart';
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

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'overview opens today with the same profit and honors masking ($width)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.reset);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final dao = AssetDao(db);
        final account = await dao.createAccount(
          AccountsCompanion.insert(name: '账户', type: 'general'),
        );
        final id = await dao.createHolding(
          HoldingsCompanion.insert(
            accountId: account,
            name: '测试产品',
            assetType: 'etf',
            quantity: const Value(100),
            costPrice: const Value(10),
            latestPrice: const Value(11.1),
          ),
        );
        final now = DateUtils.dateOnly(DateTime.now());
        for (final day in [now.subtract(const Duration(days: 1)), now]) {
          final value = day == now ? 1110.0 : 1100.0;
          await dao.upsertSnapshot(
            SnapshotsCompanion.insert(
              date: Formats.date(day),
              totalValue: value,
              totalCost: 1000,
              holdingValues: Value(
                encodeHoldingValues([
                  DayHoldingValue(
                    holdingId: id,
                    name: '测试产品',
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
              marketServiceProvider.overrideWithValue(_NoMarket(dao)),
              portfolioIntradayProvider.overrideWith(
                (ref, day) => Stream.value([]),
              ),
              portfolioIntradayHistoryProvider.overrideWith(
                (ref, day) async => (
                  points: [
                    (minute: 575, profit: -12.0),
                    (minute: 576, profit: 8.0),
                  ],
                  covered: 1,
                  eligible: 1,
                ),
              ),
              hideAmountsProvider.overrideWith((ref) => false),
            ],
            child: const AssetTrackerApp(),
          ),
        );
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(
          find.descendant(
            of: find.byType(AssetOverviewCard),
            matching: find.text('+10.00'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('今日快照收益'));
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(find.byType(DayDetailSheet), findsOneWidget);
        expect(find.text('${Formats.date(now)} 当日收益明细'), findsOneWidget);
        expect(find.text('日历收益 +¥10.00'), findsOneWidget);
        await tester.tap(find.text('分时走势'));
        await tester.pumpAndSettle();
        final sheet = find.byType(DayDetailSheet);
        final liveChart = find.descendant(
          of: sheet,
          matching: find.byType(IntradayLineChart),
        );
        expect(liveChart, findsOneWidget);
        expect(
          find.descendant(of: sheet, matching: find.text('¥0')),
          findsOneWidget,
        );
        final container = ProviderScope.containerOf(tester.element(sheet));
        container.read(hideAmountsProvider.notifier).state = true;
        await tester.pump();
        expect(liveChart, findsNothing);
        expect(
          find.descendant(of: sheet, matching: find.text('金额已隐藏')),
          findsOneWidget,
        );
        container.read(hideAmountsProvider.notifier).state = false;
        await tester.tap(find.text('收益明细'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(DayDetailSheet),
            matching: find.text('测试产品'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(HoldingKlinePage), findsOneWidget);
        expect(
          GoRouter.of(
            tester.element(find.byType(HoldingKlinePage)),
          ).state.uri.path,
          '/holdings/$id',
        );
        expect(find.text('持仓信息'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(DayDetailSheet), findsOneWidget);
        Navigator.of(tester.element(find.byType(DayDetailSheet))).pop();
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        if (width < 1100) {
          await tester.tap(find.byTooltip('收益日历'));
        } else {
          await tester.tap(find.text('收益日历'));
        }
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(find.byType(EarningsCalendarPage), findsOneWidget);
        expect(find.text('${Formats.date(now)} 当日收益明细'), findsOneWidget);
        expect(find.text('日历收益 +¥10.00'), findsOneWidget);
        expect(find.textContaining('明细合计 +¥10.00'), findsOneWidget);
        final router = GoRouter.of(
          tester.element(find.byType(EarningsCalendarPage)),
        );
        if (width < 1100) {
          await tester.tap(find.byTooltip('设置'));
          await tester.pumpAndSettle();
          expect(router.state.uri.path, '/settings');
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(router.state.uri.path, '/earnings-calendar');
        }
        await tester.tap(find.byTooltip('返回'));
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(router.state.uri.path, '/portfolio');

        router.go('/earnings-calendar');
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        await tester.binding.handlePopRoute();
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(router.state.uri.path, '/stats');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      },
    );
  }

  testWidgets('calendar distinguishes zero profit from missing snapshots', (
    tester,
  ) async {
    final day = DateTime.now();
    final snapshot = SnapshotRow(
      date: Formats.date(day),
      currency: 'CNY',
      totalValue: 1000,
      totalCost: 1000,
      liabilities: 0,
      createdAt: day,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          snapshotsProvider.overrideWith((ref) => Stream.value([snapshot])),
          transactionsProvider.overrideWith((ref) => Stream.value([])),
          historySyncProvider.overrideWith((ref) async => null),
          hideAmountsProvider.overrideWith((ref) => false),
        ],
        child: const MaterialApp(home: EarningsCalendarPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('+0.00'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('暂无快照'), findsOneWidget);
    expect(find.text('+0.00'), findsNothing);
    await tester.tap(find.text('年'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('暂无快照'), findsOneWidget);
    expect(find.text('+0.00'), findsNothing);
  });

  testWidgets('a gap shows the interval total separately from the daily cell', (
    tester,
  ) async {
    SnapshotRow snapshot(String date, double value) => SnapshotRow(
      date: date,
      currency: 'CNY',
      totalValue: value,
      totalCost: 1000,
      liabilities: 0,
      createdAt: DateTime.parse(date),
      holdingValues: encodeHoldingValues([
        DayHoldingValue(
          holdingId: 1,
          name: '测试产品',
          type: AssetType.etf,
          value: value,
          cost: 1000,
          liability: false,
        ),
      ]),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          snapshotsProvider.overrideWith(
            (ref) => Stream.value([
              snapshot('2026-01-28', 1000),
              snapshot('2026-02-03', 1030),
            ]),
          ),
          transactionsProvider.overrideWith((ref) => Stream.value([])),
          historySyncProvider.overrideWith((ref) async => null),
          hideAmountsProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          home: EarningsCalendarPage(initialDate: DateTime(2026, 2, 3)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('待核对'), findsOneWidget);
    expect(find.text('缺'), findsOneWidget);
    final detail = find.text('中间缺少快照 · 区间收益 +¥30.00');
    await tester.scrollUntilVisible(
      detail,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(detail, findsOneWidget);
    expect(find.text('日历收益 +¥30.00'), findsNothing);
  });

  testWidgets(
    'trend sheet shows daily change, and masks the whole explanation',
    (tester) async {
      final day = DateTime(2026, 11, 5);
      SnapshotRow snapshot(String date, double value) => SnapshotRow(
        date: date,
        currency: 'CNY',
        totalValue: value,
        totalCost: 1000,
        liabilities: 0,
        createdAt: day,
        holdingValues: encodeHoldingValues([
          DayHoldingValue(
            holdingId: 1,
            name: '测试产品',
            type: AssetType.etf,
            value: value,
            cost: 1000,
            liability: false,
          ),
        ]),
      );
      final container = ProviderContainer(
        overrides: [
          snapshotsProvider.overrideWith(
            (ref) => Stream.value([
              snapshot('2026-11-04', 1100),
              snapshot('2026-11-05', 1125),
            ]),
          ),
          transactionsProvider.overrideWith((ref) => Stream.value([])),
          hideAmountsProvider.overrideWith((ref) => false),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: DayDetailSheet(date: day)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('日历收益 +¥25.00'), findsOneWidget);
      expect(find.text('+¥125.00'), findsNothing);
      container.read(hideAmountsProvider.notifier).state = true;
      await tester.pump();
      expect(find.text('日历收益 ¥•••••'), findsOneWidget);
      expect(find.textContaining('25.00'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
