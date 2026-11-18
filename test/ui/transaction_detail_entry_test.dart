import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/components/transaction_tile.dart';
import 'package:asset_tracker/ui/pages/accounts/account_detail_page.dart';
import 'package:asset_tracker/ui/pages/holdings/holding_kline_page.dart';
import 'package:asset_tracker/ui/pages/transactions/transactions_page.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(AppDatabase, TransactionRow)> _fixture() async {
  final db = AppDatabase(NativeDatabase.memory());
  final dao = AssetDao(db);
  final accountId = await dao.createAccount(
    AccountsCompanion.insert(name: '测试账户', type: 'general'),
  );
  final holdingId = await dao.createHolding(
    HoldingsCompanion.insert(
      accountId: accountId,
      name: '测试 ETF',
      assetType: 'etf',
      quantity: const Value(12),
      costPrice: const Value(3.25),
      latestPrice: const Value(3.25),
    ),
  );
  await dao.createTransaction(
    TransactionsCompanion.insert(
      accountId: accountId,
      holdingId: Value(holdingId),
      type: 'buy',
      quantity: const Value(12),
      price: const Value(3.25),
      amount: 39,
      occurredAt: DateTime(2026, 9, 21, 14, 45),
      note: const Value('测试备注'),
    ),
  );
  return (db, (await dao.getTransactions()).single);
}

void main() {
  Future<void> pumpFixture(
    WidgetTester tester,
    AppDatabase db,
    Widget page,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(db.close);
    final dao = AssetDao(db);
    final accounts = await dao.getAccounts();
    final holdings = await dao.getHoldings();
    final transactions = await dao.getTransactions();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          hideAmountsProvider.overrideWith((ref) => false),
          historySyncProvider.overrideWith((ref) => null),
          accountsProvider.overrideWith((ref) => Stream.value(accounts)),
          accountProvider(1).overrideWith((ref) async => accounts.single),
          holdingsProvider.overrideWith((ref) => Stream.value(holdings)),
          holdingsByAccountProvider(
            1,
          ).overrideWith((ref) => Stream.value(holdings)),
          transactionsProvider.overrideWith(
            (ref) => Stream.value(transactions),
          ),
          transactionsByAccountProvider(
            1,
          ).overrideWith((ref) => Stream.value(transactions)),
          cnyRatesProvider.overrideWith((ref) async => {}),
        ],
        child: MaterialApp(home: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectDetail(WidgetTester tester) async {
    await tester.pumpAndSettle();
    expect(find.text('交易详情'), findsOneWidget);
    expect(find.text('成交价'), findsOneWidget);
    expect(find.text('3.25'), findsOneWidget);
    expect(find.text('数量'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('测试备注'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  testWidgets('持仓流水点按显示记录详情，删除操作保持独立', (tester) async {
    final (db, transaction) = await _fixture();
    await pumpFixture(
      tester,
      db,
      Scaffold(body: TransactionTile(txn: transaction)),
    );
    await tester.tap(find.text('买入'));
    await expectDetail(tester);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除流水（自动回滚持仓）'));
    await tester.pumpAndSettle();
    expect(find.text('删除流水'), findsOneWidget);
    expect(find.text('交易详情'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('账户流水点按显示成交价和数量', (tester) async {
    final (db, _) = await _fixture();
    await pumpFixture(tester, db, const AccountDetailPage(accountId: 1));
    await tester.tap(find.text('交易流水'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('买入'));
    await expectDetail(tester);
    await tester.tap(find.text('测试 ETF'));
    await tester.pumpAndSettle();
    expect(find.byType(HoldingKlinePage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('交易详情'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('交易详情'), findsNothing);
    expect(find.byType(AccountDetailPage), findsOneWidget);
    expect(find.text('买入'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, '持仓'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试 ETF'));
    await tester.pumpAndSettle();
    expect(find.byType(HoldingKlinePage), findsOneWidget);
    expect(find.text('记一笔'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('全局流水先显示详情并保留修改日期入口', (tester) async {
    final (db, _) = await _fixture();
    await pumpFixture(tester, db, const TransactionsPage());
    final tile = find.byType(TransactionTile);
    await tester.ensureVisible(tile);
    await tester.tap(find.descendant(of: tile, matching: find.text('买入')));
    await expectDetail(tester);
    await tester.tap(find.text('修改日期'));
    await tester.pumpAndSettle();
    expect(find.text('修改流水日期'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('旧转入和转出记录按资金方向显示还款', (tester) async {
    final (db, purchase) = await _fixture();
    final dao = AssetDao(db);
    final cashId = await dao.createHolding(
      HoldingsCompanion.insert(
        accountId: purchase.accountId,
        name: '天天宝',
        assetType: 'liquid_wealth',
      ),
    );
    final cardId = await dao.createHolding(
      HoldingsCompanion.insert(
        accountId: purchase.accountId,
        name: '信用卡',
        assetType: 'liability',
      ),
    );
    for (final (type, source, target, amount) in [
      ('transfer_in', cashId, cardId, 500.0),
      ('transfer_out', cashId, cardId, 300.0),
      ('transfer_out', cardId, cashId, 200.0),
    ]) {
      await dao.createTransaction(
        TransactionsCompanion.insert(
          accountId: purchase.accountId,
          type: type,
          cashSourceId: Value(source),
          cashTargetId: Value(target),
          amount: amount,
          occurredAt: DateTime(2026, 9, 22),
        ),
      );
    }

    await pumpFixture(tester, db, const TransactionsPage());
    expect(find.text('信用卡还款'), findsNWidgets(2));
    expect(find.text('¥500.00'), findsOneWidget);
    final payment = find.text('信用卡还款').first;
    await tester.ensureVisible(payment);
    await tester.tap(payment);
    await tester.pumpAndSettle();
    expect(find.text('资金来源'), findsOneWidget);
    expect(find.text('还款账户'), findsOneWidget);
    expect(find.text('测试账户 / 天天宝'), findsOneWidget);
    expect(find.text('测试账户 / 信用卡'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    // Replace the route under the same provider scope to check the account list.
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => AccountDetailPage(accountId: purchase.accountId),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('交易流水'));
    await tester.pumpAndSettle();
    expect(find.text('信用卡还款'), findsNWidgets(2));
    expect(find.text('账户内转账'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
