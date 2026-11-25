import 'dart:async';

import 'package:asset_tracker/app/category_earnings_provider.dart';
import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/category_earnings.dart';
import 'package:asset_tracker/domain/earnings_breakdown.dart';
import 'package:asset_tracker/ui/pages/stats/category_earnings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _categories = [
  CategoryEarning(
    category: AssetCategory.equity,
    profit: 250,
    rate: .025,
    products: [
      CategoryProductEarning(
        name: '宽基基金',
        holdingIds: [1],
        profit: 250,
        rate: .025,
        closed: false,
      ),
    ],
  ),
  CategoryEarning(
    category: AssetCategory.gold,
    profit: -50,
    rate: -.01,
    products: [
      CategoryProductEarning(
        name: '黄金ETF',
        holdingIds: [2],
        profit: -50,
        rate: -.01,
        closed: true,
      ),
    ],
  ),
];

CategoryEarningsReport _report(
  CategoryEarningsPeriod period, {
  List<CategoryEarning> categories = _categories,
  int days = 12,
  double? totalRate = .02,
  List<EarningsAttributionIssue> issues = const [],
}) => CategoryEarningsReport(
  from: period.from,
  to: period.to,
  categories: categories,
  totalProfit: 200,
  totalRate: totalRate,
  days: days,
  issues: issues,
);

Future<void> _pump(
  WidgetTester tester, {
  double width = 390,
  AssetCategory? initialCategory,
  FutureOr<CategoryEarningsReport> Function(CategoryEarningsPeriod)? load,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 950);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        categoryEarningsProvider.overrideWith(
          (ref, period) async =>
              load == null ? _report(period) : await load(period),
        ),
        hideAmountsProvider.overrideWith((ref) => false),
        historySyncProvider.overrideWith((ref) async => null),
        alertEventsProvider.overrideWith(
          (ref) => Stream.value(<AlertEventRow>[]),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: CategoryEarningsPage(initialCategory: initialCategory),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets(
    'period selection passes inclusive dates and custom dates can be edited again',
    (tester) async {
      final requests = <CategoryEarningsPeriod>[];
      await _pump(
        tester,
        load: (period) {
          requests.add(period);
          return _report(period);
        },
      );
      final now = DateTime.now();
      expect(requests.last, (
        from: Formats.date(DateTime(now.year, now.month)),
        to: Formats.date(now),
      ));
      await tester.tap(find.byKey(const ValueKey('category-period-year')));
      await tester.pumpAndSettle();
      expect(requests.last.from, Formats.date(DateTime(now.year)));

      await tester.tap(find.byKey(const ValueKey('category-period-custom')));
      await tester.pumpAndSettle();
      expect(find.text('选择收益区间'), findsOneWidget);
      await tester.tap(find.byTooltip('Switch to input'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      final start = DateTime(now.year, now.month - 1, 2);
      final end = DateTime(now.year, now.month - 1, 5);
      final localizations = MaterialLocalizations.of(
        tester.element(fields.first),
      );
      await tester.enterText(
        fields.first,
        localizations.formatCompactDate(start),
      );
      await tester.enterText(fields.last, localizations.formatCompactDate(end));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(requests.last, (from: Formats.date(start), to: Formats.date(end)));
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('category-period-custom')),
            )
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('category-period-custom')));
      await tester.pumpAndSettle();
      expect(find.text('选择收益区间'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'categories expand products and selected category is visible on entry',
    (tester) async {
      await _pump(tester, initialCategory: AssetCategory.gold);
      expect(find.text('黄金ETF'), findsOneWidget);
      expect(find.text('期末已清仓'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('category-row-gold'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('category-row-equity')))
              .dy,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('category-row-equity')));
      await tester.pump();
      expect(find.text('宽基基金'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('category-row-gold')));
      await tester.pump();
      expect(find.text('黄金ETF'), findsNothing);
      expect(
        find.byKey(const ValueKey('category-products-equity')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'privacy masks summary, product amounts, rates and comparison bars',
    (tester) async {
      await _pump(tester, initialCategory: AssetCategory.gold);
      expect(find.text('+¥200.00'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('category-profit-bar-equity')),
        findsOneWidget,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CategoryEarningsPage)),
      );
      container.read(hideAmountsProvider.notifier).state = true;
      await tester.pump();
      expect(find.textContaining('200.00'), findsNothing);
      expect(find.textContaining('50.00'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(
        find.byKey(const ValueKey('category-profit-bar-equity')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('category-profit-bar-gold')),
        findsNothing,
      );
      expect(find.text('****'), findsWidgets);
      container.read(hideAmountsProvider.notifier).state = false;
      await tester.pump();
      expect(find.text('+¥200.00'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('category-profit-bar-gold')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'unverified periods hide all partial totals even without in-range snapshots',
    (tester) async {
      await _pump(
        tester,
        load: (period) => _report(
          period,
          days: 0,
          issues: const [
            EarningsAttributionIssue(date: '2026-10-02', message: '快照断档跨越所选区间'),
          ],
        ),
      );
      expect(find.text('该区间收益待核对'), findsOneWidget);
      expect(find.text('快照断档跨越所选区间'), findsOneWidget);
      expect(find.text('该区间暂无收益快照'), findsNothing);
      expect(
        find.byKey(const ValueKey('category-summary-profit')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('category-row-equity')), findsNothing);
    },
  );

  testWidgets(
    'empty period provides guidance and does not report zero earnings',
    (tester) async {
      await _pump(
        tester,
        load: (period) => _report(period, days: 0, categories: []),
      );
      expect(find.text('该区间暂无收益快照'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('category-summary-profit')),
        findsNothing,
      );
      expect(find.textContaining('可以切换时间区间'), findsOneWidget);
    },
  );

  testWidgets('failed request can be retried without changing the range', (
    tester,
  ) async {
    var attempts = 0;
    await _pump(
      tester,
      load: (period) {
        if (++attempts == 1) throw StateError('offline');
        return _report(period);
      },
    );
    expect(find.text('分类收益加载失败，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('+¥200.00'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('pending request shows a loading state', (tester) async {
    final completer = Completer<CategoryEarningsReport>();
    CategoryEarningsPeriod? requested;
    await _pump(
      tester,
      load: (period) {
        requested = period;
        return completer.future;
      },
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    completer.complete(_report(requested!));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('+¥200.00'), findsOneWidget);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('very large return rates fit at width $width', (tester) async {
      await _pump(
        tester,
        width: width,
        initialCategory: AssetCategory.equity,
        load: (period) => _report(
          period,
          totalRate: 1e20,
          categories: const [
            CategoryEarning(
              category: AssetCategory.equity,
              profit: 1e20,
              rate: 1e20,
              products: [
                CategoryProductEarning(
                  name: '很小的期初基数产生很大的区间收益率',
                  holdingIds: [1],
                  profit: 1e20,
                  rate: 1e20,
                  closed: false,
                ),
              ],
            ),
          ],
        ),
      );
      expect(
        find.byKey(const ValueKey('category-summary-rate')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('long product names and large amounts fit at width $width', (
      tester,
    ) async {
      await _pump(
        tester,
        width: width,
        initialCategory: AssetCategory.equity,
        load: (period) => _report(
          period,
          categories: const [
            CategoryEarning(
              category: AssetCategory.equity,
              profit: 123456789012345.67,
              rate: null,
              products: [
                CategoryProductEarning(
                  name: '这是一个很长的跨账户合并产品名称用于核对手机屏幕能否完整显示且不会挤出收益数字',
                  holdingIds: [1, 2],
                  profit: 123456789012345.67,
                  rate: null,
                  closed: false,
                ),
              ],
            ),
          ],
        ),
      );
      expect(find.text('--'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
