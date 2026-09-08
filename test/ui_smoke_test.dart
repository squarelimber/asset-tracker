// Overflow / build regression smoke tests: every main page is pumped at a
// phone (360x640) and a desktop (1280x800) viewport with a fully seeded
// in-memory database. Any RenderFlex overflow or build exception is
// captured and fails the test.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/market/global_quote_source.dart';
import 'package:asset_tracker/ui/pages/accounts/account_detail_page.dart';
import 'package:asset_tracker/ui/pages/accounts/accounts_page.dart';
import 'package:asset_tracker/ui/pages/alerts/alerts_page.dart';
import 'package:asset_tracker/ui/pages/calendar/earnings_calendar_page.dart';
import 'package:asset_tracker/ui/pages/calendar/product_earnings_calendar_page.dart';
import 'package:asset_tracker/ui/pages/holdings/holdings_page.dart';
import 'package:asset_tracker/ui/pages/markets/markets_page.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_page.dart';
import 'package:asset_tracker/ui/pages/settings/settings_page.dart';
import 'package:asset_tracker/ui/pages/stats/stats_page.dart';
import 'package:asset_tracker/ui/pages/transactions/transactions_page.dart';

const _fakeQuotes = [
  GlobalQuote(
    code: 'sh000001',
    name: '上证指数',
    group: 'A股',
    price: 3500,
    change: 10,
    changePct: 0.29,
  ),
  GlobalQuote(
    code: 'rt_hkHSI',
    name: '恒生指数',
    group: '亚太',
    price: 20000,
    change: -50,
    changePct: -0.25,
  ),
  GlobalQuote(
    code: 'hf_XAU',
    name: '伦敦金',
    group: '大宗商品',
    price: 2400,
    change: 5,
    changePct: 0.21,
    unit: '美元/盎司',
  ),
  GlobalQuote(
    code: 'fx_usdcny',
    name: '美元',
    group: '货币',
    price: 7.2,
    change: 0.01,
    changePct: 0.14,
    fxSymbol: 'USD',
  ),
];

/// Seeds a CNY-only database (no foreign currencies, so no FX network
/// calls) covering every page: two accounts, five holdings (stock, fund,
/// bank deposit, liability, closed-out), six transactions across three
/// months, ten daily snapshots, one alert rule and one alert event.
Future<({AppDatabase db, int accountA, int accountB})> _seedDb() async {
  final db = AppDatabase(NativeDatabase.memory());
  final dao = AssetDao(db);

  final accountA =
      await dao.createAccount(AccountsCompanion.insert(name: '证券账户', type: 'general'));
  final accountB =
      await dao.createAccount(AccountsCompanion.insert(name: '银行账户', type: 'bank'));

  final stock = await dao.createHolding(HoldingsCompanion.insert(
    accountId: accountA,
    name: '贵州茅台',
    assetType: 'stock',
    symbol: const Value('sh600519'),
    quantity: const Value(100),
    costPrice: const Value(1500),
    latestPrice: const Value(1600),
    purchaseDate: Value(DateTime(2026, 6, 1)),
  ));
  final fund = await dao.createHolding(HoldingsCompanion.insert(
    accountId: accountA,
    name: '测试基金',
    assetType: 'mutual_fund',
    symbol: const Value('sz110022'),
    quantity: const Value(1000),
    costPrice: const Value(2.5),
    latestPrice: const Value(2.8),
    purchaseDate: Value(DateTime(2026, 7, 1)),
  ));
  await dao.createHolding(HoldingsCompanion.insert(
    accountId: accountB,
    name: '活期存款',
    assetType: 'bank_deposit',
    quantity: const Value(50000),
    costPrice: const Value(50000),
    latestPrice: const Value(1),
  ));
  await dao.createHolding(HoldingsCompanion.insert(
    accountId: accountB,
    name: '信用卡',
    assetType: 'liability',
    quantity: const Value(2000),
    costPrice: const Value(1),
    latestPrice: const Value(1),
  ));
  await dao.createHolding(HoldingsCompanion.insert(
    accountId: accountA,
    name: '已清仓股票',
    assetType: 'stock',
    symbol: const Value('sz000001'),
    quantity: const Value(0),
    costPrice: const Value(10),
    latestPrice: const Value(10),
    purchaseDate: Value(DateTime(2026, 5, 1)),
  ));

  await dao.createTransaction(TransactionsCompanion.insert(
    accountId: accountA,
    holdingId: Value(stock),
    type: 'buy',
    quantity: const Value(100),
    price: const Value(1500),
    amount: 150000,
    occurredAt: DateTime(2026, 6, 1),
  ));
  await dao.createTransaction(TransactionsCompanion.insert(
    accountId: accountA,
    holdingId: Value(fund),
    type: 'buy',
    quantity: const Value(1000),
    price: const Value(2.5),
    amount: 2500,
    occurredAt: DateTime(2026, 7, 1),
  ));
  await dao.createTransaction(TransactionsCompanion.insert(
    accountId: accountA,
    holdingId: Value(stock),
    type: 'sell',
    quantity: const Value(20),
    price: const Value(1650),
    amount: 33000,
    occurredAt: DateTime(2026, 8, 10),
  ));
  await dao.createTransaction(TransactionsCompanion.insert(
    accountId: accountA,
    holdingId: Value(stock),
    type: 'dividend',
    amount: 500,
    occurredAt: DateTime(2026, 8, 15),
  ));
  await dao.createTransaction(TransactionsCompanion.insert(
    accountId: accountB,
    type: 'income',
    amount: 8000,
    occurredAt: DateTime(2026, 8, 20),
  ));
  await dao.createTransaction(TransactionsCompanion.insert(
    accountId: accountB,
    type: 'expense',
    amount: 1200,
    occurredAt: DateTime(2026, 8, 21),
  ));

  final now = DateTime.now();
  for (var i = 10; i >= 1; i--) {
    final d = now.subtract(Duration(days: i));
    String two(int n) => n.toString().padLeft(2, '0');
    await dao.upsertSnapshot(SnapshotsCompanion.insert(
      date: '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}',
      currency: const Value('CNY'),
      totalValue: 200000 + (10 - i) * 500,
      totalCost: 177500,
      liabilities: const Value(2000),
    ));
  }

  final rule = await dao.createAlertRule(AlertRulesCompanion.insert(
    type: 'concentration',
    name: '集中度提醒',
    params: const Value('{"threshold":0.5}'),
  ));
  await dao.createAlertEvent(AlertEventsCompanion.insert(
    ruleId: rule,
    title: '集中度提醒',
    message: '单一持仓占比超过 50%',
  ));

  return (db: db, accountA: accountA, accountB: accountB);
}

List<Override> _overrides(AppDatabase db) => [
      databaseProvider.overrideWithValue(db),
      quotesProvider.overrideWith((ref) async => _fakeQuotes),
      historySyncProvider.overrideWith((ref) async => null),
      productEarningsProvider.overrideWith((ref, year) async => const []),
    ];

void _smokePage(
  String name,
  Widget Function() build, {
  required Size size,
}) {
  testWidgets('$name @ ${size.width}x${size.height}', (tester) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final seed = await _seedDb();

    await tester.pumpWidget(ProviderScope(
      overrides: _overrides(seed.db),
      child: MaterialApp(home: build()),
    ));
    // Let stream/future providers settle (fixed pumps, not pumpAndSettle,
    // so a lingering spinner cannot hang the test).
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    // Close the db inside the body: the test framework replaces the root
    // widget after the body to unmount the tree, and closing drift streams
    // first keeps that unmount from scheduling a pending timer.
    await tester.pump(const Duration(milliseconds: 500));
    await seed.db.close();
    await tester.pump();
  });
}

void main() {
  final phone = const Size(360, 640);
  final desktop = const Size(1280, 800);

  for (final size in [phone, desktop]) {
    final label = size == phone ? 'phone' : 'desktop';
    group('smoke $label', () {
      _smokePage('MarketsPage', () => const MarketsPage(), size: size);
      _smokePage('PortfolioPage', () => const PortfolioPage(), size: size);
      _smokePage('HoldingsPage', () => const HoldingsPage(), size: size);
      _smokePage('AccountsPage', () => const AccountsPage(), size: size);
      _smokePage('StatsPage', () => const StatsPage(), size: size);
      _smokePage('EarningsCalendarPage', () => const EarningsCalendarPage(), size: size);
      _smokePage('ProductEarningsCalendarPage', () => const ProductEarningsCalendarPage(), size: size);
      _smokePage('AlertsPage', () => const AlertsPage(), size: size);
      _smokePage('SettingsPage', () => const SettingsPage(), size: size);
      _smokePage('TransactionsPage', () => const TransactionsPage(), size: size);
    });
  }

  group('smoke detail', () {
    testWidgets('AccountDetailPage @ phone', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final seed = await _seedDb();

      await tester.pumpWidget(ProviderScope(
        overrides: _overrides(seed.db),
        child: MaterialApp(home: AccountDetailPage(accountId: seed.accountA)),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 500));
      await seed.db.close();
      await tester.pump();
    });
  });
}
