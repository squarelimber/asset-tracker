import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/market/global_quote_source.dart';
import 'package:asset_tracker/ui/components/quote_table.dart';
import 'package:asset_tracker/ui/components/terminal_choice.dart';
import 'package:asset_tracker/ui/pages/markets/markets_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('手机行情按市场分组并可筛选', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        historySyncProvider.overrideWith((ref) => null),
        quotesProvider.overrideWith(
          (ref) async => const [
            GlobalQuote(
              code: 'sh000001',
              name: '上证指数',
              group: 'A股',
              price: 3300,
              change: 1,
              changePct: 0.01,
            ),
            GlobalQuote(
              code: 'rt_hkHSI',
              name: '恒生指数',
              group: '亚太',
              price: 25000,
              change: -3,
              changePct: -0.01,
            ),
            GlobalQuote(
              code: 'int_nikkei',
              name: '日经225',
              group: '亚太',
              price: 50000,
              change: 2,
              changePct: 0.01,
            ),
          ],
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: const MarketsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('上证指数'), findsOneWidget);
    expect(find.text('恒生指数'), findsOneWidget);
    final cards = tester
        .widgetList<QuoteTable>(find.byType(QuoteTable))
        .toList();
    expect(cards.map((card) => card.group), containsAll(['A股', '港股', '日股']));
    expect(cards.every((card) => card.sessionLabel != null), isTrue);
    final filter = find.widgetWithText(TerminalChoice, '港股');
    expect(tester.getSize(filter).width, 64);
    expect(tester.getSize(filter).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(find.text('港股').first).width, greaterThan(20));
    await tester.tap(filter);
    await tester.pump();
    expect(find.text('恒生指数'), findsOneWidget);
    expect(find.text('上证指数'), findsNothing);
    expect(find.text('日经225'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
