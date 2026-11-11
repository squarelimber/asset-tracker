import 'dart:convert';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/market/kline_source.dart';
import 'package:asset_tracker/ui/pages/holdings/holding_kline_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('持仓图表按持仓代码加载，隐藏金额并保留详情', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    final holding = HoldingRow(
      id: 1,
      accountId: 1,
      name: '测试ETF',
      assetType: 'etf',
      marketSource: 'manual',
      symbol: '510300',
      quantity: 1000,
      costPrice: 3,
      latestPrice: 4,
      currency: 'CNY',
      costRecorded: true,
      archived: false,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final requests = <String>[];
    final client = MockClient((request) async {
      final param = request.url.queryParameters['param']!;
      requests.add(param);
      final parts = param.split(',');
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            parts[0]: {
              parts[1]: [
                ['2026-11-06', '3', '4', '4', '3', '500'],
              ],
            },
          },
        }),
        200,
      );
    });
    final trades = [
      for (final (id, type, hour) in [(1, 'buy', 10), (2, 'sell', 14)])
        TransactionRow(
          id: id,
          accountId: 1,
          holdingId: 1,
          type: type,
          quantity: 5,
          price: 3.45,
          amount: 17.25,
          currency: 'CNY',
          occurredAt: DateTime(2026, 11, 6, hour),
          costMoved: false,
          internalMove: false,
          updatedAt: DateTime(2026, 11, 6, hour),
        ),
    ];
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        holdingsProvider.overrideWith((ref) => Stream.value([holding])),
        transactionsByHoldingProvider(
          1,
        ).overrideWith((ref) => Stream.value(trades)),
        priceCacheProvider.overrideWith((ref) => Future.value({})),
        historySyncProvider.overrideWith((ref) => null),
      ],
    );
    addTearDown(() async {
      container.dispose();
      client.close();
      await db.close();
    });
    container.read(hideAmountsProvider.notifier).state = true;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: HoldingKlinePage(
            holdingId: 1,
            source: KlineSource(client: client),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests.first, startsWith('sh510300,day,'));
    expect(requests.first, endsWith(',bfq'));
    expect(find.textContaining('持有市值 ****'), findsOneWidget);
    expect(find.textContaining('持仓收益 ****'), findsOneWidget);
    expect(find.text('测试ETF'), findsOneWidget);
    expect(find.text('持仓信息'), findsOneWidget);
    expect(find.text('记一笔'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    expect(find.text('交易流水'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final tradeMarker = find.byTooltip('1 个交易日 · 2 笔交易');
    expect(tradeMarker, findsOneWidget);
    await tester.ensureVisible(tradeMarker);
    await tester.tap(tradeMarker);
    await tester.pumpAndSettle();
    expect(find.text('交易记录'), findsOneWidget);
    expect(find.textContaining('成交价 ****'), findsNWidgets(2));
    expect(find.textContaining('数量 ****'), findsNWidgets(2));
    expect(find.textContaining('金额 ****'), findsNWidgets(2));
    expect(find.textContaining('17.25'), findsNothing);
    Navigator.of(tester.element(find.text('交易记录'))).pop();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('周 K'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('周 K'));
    await tester.pumpAndSettle();
    expect(requests.last, startsWith('sh510300,week,'));
    expect(requests.last, endsWith(',bfq'));
  });

  testWidgets('行情失败时仍可查看持仓和流水', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    final holding = HoldingRow(
      id: 1,
      accountId: 1,
      name: '测试ETF',
      assetType: 'etf',
      marketSource: 'sina',
      symbol: '510300',
      quantity: 1000,
      costPrice: 3,
      latestPrice: 4,
      currency: 'CNY',
      costRecorded: true,
      archived: false,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final client = MockClient((_) async => http.Response('', 503));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        holdingsProvider.overrideWith((ref) => Stream.value([holding])),
        transactionsByHoldingProvider(
          1,
        ).overrideWith((ref) => Stream.value([])),
        priceCacheProvider.overrideWith((ref) => Future.value({})),
        historySyncProvider.overrideWith((ref) => null),
      ],
    );
    addTearDown(() async {
      container.dispose();
      client.close();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: HoldingKlinePage(
            holdingId: 1,
            source: KlineSource(client: client),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未能获取 K 线数据，请检查网络后重试'), findsOneWidget);
    expect(find.text('交易流水'), findsOneWidget);
    expect(find.text('数量/份额'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不支持 K 线的直接链接保留持仓名称和记账入口', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final holding = HoldingRow(
      id: 1,
      accountId: 1,
      name: '定期存款',
      assetType: 'bank_deposit',
      marketSource: 'manual',
      symbol: null,
      quantity: 100,
      costPrice: 100,
      latestPrice: 1,
      currency: 'CNY',
      costRecorded: true,
      archived: false,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        holdingsProvider.overrideWith((ref) => Stream.value([holding])),
        transactionsByHoldingProvider(
          1,
        ).overrideWith((ref) => Stream.value([])),
        priceCacheProvider.overrideWith((ref) => Future.value({})),
        historySyncProvider.overrideWith((ref) => null),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HoldingKlinePage(holdingId: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('定期存款'), findsOneWidget);
    expect(find.text('持仓信息'), findsOneWidget);
    expect(find.text('记一笔'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
