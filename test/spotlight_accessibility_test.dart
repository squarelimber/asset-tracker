import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/services/history_backfill_service.dart';
import 'package:asset_tracker/ui/components/rotating_spotlight_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final desktop in [false, true]) {
    testWidgets(
      'spotlight respects reduced motion and amount masking ($desktop)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = desktop
            ? const Size(1280, 800)
            : const Size(390, 844);
        addTearDown(tester.view.reset);
        final container = ProviderContainer(
          overrides: [
            spotlightHoldMsProvider.overrideWith((ref) => Stream.value(2300)),
            productEarningsProvider.overrideWith((ref, year) async => const []),
            dayHoldingsBreakdownProvider.overrideWith((ref, day) async {
              final today = DateUtils.dateOnly(DateTime.now());
              final previous = day.isBefore(today);
              return [
                DayHoldingValue(
                  holdingId: 1,
                  name: '演示基金',
                  type: AssetType.etf,
                  value: previous ? 90 : 100,
                  cost: 80,
                  liability: false,
                ),
                DayHoldingValue(
                  holdingId: 2,
                  name: '演示股票',
                  type: AssetType.stock,
                  value: previous ? 220 : 200,
                  cost: 200,
                  liability: false,
                ),
              ];
            }),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
              home: const Scaffold(body: RotatingSpotlightCard()),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(seconds: 10));
        expect(find.text('今日最佳'), findsOneWidget);
        expect(find.text('+${Formats.amount(10)}'), findsNothing);
        expect(
          find.text(Formats.masked()),
          desktop ? findsNWidgets(2) : findsOneWidget,
        );
        container.read(hideAmountsProvider.notifier).state = false;
        await tester.pump();
        expect(find.text('+${Formats.amount(10)}'), findsOneWidget);
        if (desktop) {
          expect(find.text('今日最差'), findsOneWidget);
          expect(find.text('本月最佳'), findsOneWidget);
        } else {
          expect(find.text('今日最差'), findsNothing);
          await tester.tap(find.byTooltip('下一项'));
          await tester.pump();
          expect(find.text('今日最差'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      },
    );
  }
}
