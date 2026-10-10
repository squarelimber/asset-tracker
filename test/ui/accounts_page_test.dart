import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/app/theme.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/accounts/accounts_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression cover for three account-page display bugs:
///  1. the header printed the currency symbol twice (¥¥640,109.86);
///  2. the type-bar legend glued the share to the amount ("0.00%0.0万");
///  3. the legend grouped by raw `AssetType.category`, ignoring the manual
///     category override — a 黄金ETF (场内基金 / etf) was filed under 权益,
///     unlike the overview page which uses `effectiveCategoryOf`.
void main() {
  HoldingRow holding({
    required int id,
    required String name,
    required String assetType,
    required double quantity,
    double latestPrice = 0,
    String? symbol,
    String? categoryOverride,
  }) {
    return HoldingRow(
      costRecorded: false,
      id: id,
      accountId: 1,
      name: name,
      assetType: assetType,
      marketSource: 'manual',
      symbol: symbol,
      quantity: quantity,
      costPrice: 0,
      latestPrice: latestPrice,
      currency: 'CNY',
      categoryOverride: categoryOverride,
      archived: false,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  /// Pumps the accounts page over an in-memory DB with the amount mask set to
  /// [hide] (the legend only renders its amount segment when shown).
  Future<void> pumpAccounts(
    WidgetTester tester,
    List<HoldingRow> holdings, {
    bool hide = false,
  }) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        historySyncProvider.overrideWith((ref) => null),
        accountsProvider.overrideWith(
          (ref) => Stream.value([
            AccountRow(
              id: 1,
              name: '测试账户',
              type: 'general',
              currency: 'CNY',
              createdAt: DateTime(2026, 1, 1),
              updatedAt: DateTime(2026, 1, 1),
            ),
          ]),
        ),
        holdingsByAccountProvider(1).overrideWith(
          (ref) => Stream.value(holdings),
        ),
        cnyRatesProvider.overrideWith((ref) => Future.value(const {'CNY': 1.0})),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    container.read(hideAmountsProvider.notifier).state = hide;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: const AccountsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('账户头部的货币符号只出现一次', (tester) async {
    await pumpAccounts(tester, [
      holding(id: 1, name: '现金', assetType: 'savings', quantity: 10000),
    ]);

    expect(
      find.textContaining('¥¥'),
      findsNothing,
      reason: 'Formats.money 已带货币符号，不能手工再拼一个',
    );
    expect(find.text('¥10,000.00 · 1 项'), findsOneWidget);
  });

  testWidgets('占比图例：百分比与金额之间有分隔符', (tester) async {
    await pumpAccounts(tester, [
      holding(id: 1, name: '现金', assetType: 'savings', quantity: 10000),
      holding(id: 2, name: '零钱', assetType: 'savings', quantity: 5000),
    ]);

    // 金额段是独立的一个 Text，以 '· ' 开头（占比 Text 与它之间还有一段间距），
    // 两者不会被读成一串 "100.00%1.5万"。
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('· '),
      ),
      findsOneWidget,
      reason: '占比与金额之间必须可分辨，不能读成一串',
    );
  });

  testWidgets('占比图例：尊重归类覆盖，且负债不参与配置', (tester) async {
    await pumpAccounts(tester, [
      // 场内基金(etf) 的天然归类是「权益」，手动覆盖成「黄金」。
      holding(
        id: 1,
        name: '黄金ETF',
        assetType: 'etf',
        symbol: '518880',
        quantity: 1000,
        latestPrice: 5,
        categoryOverride: 'gold',
      ),
      holding(id: 2, name: '现金', assetType: 'savings', quantity: 10000),
      // 信用卡：总览页口径里负债不进配置，也不该撑大这里的占比分母。
      holding(id: 3, name: '信用卡', assetType: 'liability', quantity: 5000),
    ]);

    // 归类覆盖生效：黄金ETF 记在「黄金」而不是天然的「权益」。
    expect(find.textContaining('黄金 '), findsOneWidget);
    expect(find.textContaining('权益'), findsNothing);

    // 负债被排除：分母 = 10,000 + 5,000 = 15,000（含负债会是 20,000 → 75%）。
    expect(find.textContaining('现金 66.67%'), findsOneWidget);
    expect(find.textContaining('黄金 33.33%'), findsOneWidget);
    expect(find.textContaining('75.00%'), findsNothing);

    // 头部总额同样只算资产。
    expect(find.text('¥15,000.00 · 3 项'), findsOneWidget);
  });

  testWidgets('隐藏金额时占比图例不显示金额段', (tester) async {
    await pumpAccounts(
      tester,
      [holding(id: 1, name: '现金', assetType: 'savings', quantity: 10000)],
      hide: true,
    );

    expect(find.text('****'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('· '),
      ),
      findsNothing,
    );
  });
}
