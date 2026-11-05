import 'package:asset_tracker/app/app.dart';
import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/services/market/market_service.dart';
import 'package:asset_tracker/ui/components/asset_overview_card.dart';
import 'package:asset_tracker/ui/pages/calendar/earnings_calendar_page.dart';
import 'package:asset_tracker/ui/pages/portfolio/day_detail_sheet.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      },
    );
  }

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
      await tester.pump();
      await tester.pump();
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
