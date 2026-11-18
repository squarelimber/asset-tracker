import 'dart:convert';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/nav_history.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/backup_service.dart';
import 'package:asset_tracker/services/market/fund_nav_source.dart';
import 'package:asset_tracker/sync/sync_format.dart';
import 'package:asset_tracker/sync/sync_merge.dart';
import 'package:asset_tracker/ui/pages/holdings/holding_kline_page.dart';
import 'package:asset_tracker/ui/pages/holdings/holding_nav_trend.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<int> addHolding(AssetDao dao, String type, {String? code}) async {
  final account = await dao.createAccount(
    AccountsCompanion.insert(name: '测试账户', type: 'general'),
  );
  return dao.createHolding(
    HoldingsCompanion.insert(
      accountId: account,
      name: '测试产品',
      assetType: type,
      symbol: Value(code),
      quantity: const Value(100),
      costPrice: const Value(1),
      latestPrice: const Value(1.5),
    ),
  );
}

void main() {
  test(
    'dated bank NAV round-trips and keeps backdated changes separate from current price',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final restoredDb = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      addTearDown(restoredDb.close);
      final dao = AssetDao(db);
      final restoredDao = AssetDao(restoredDb);
      final id = await addHolding(dao, 'bank_wealth');
      final today = DateTime(2026, 11, 18);
      final yesterday = DateTime(2026, 11, 17);

      await dao.recordManualNav(id, yesterday, 1.2, now: today);
      expect((await dao.getHolding(id))!.latestPrice, 1.5);
      await dao.recordManualNav(id, today, 1.3, now: today);
      await dao.recordManualNav(id, yesterday, 1.25, now: today);
      expect((await dao.getHolding(id))!.latestPrice, 1.3);
      await expectLater(
        dao.recordManualNav(id, DateTime(2026, 11, 19), 1.4, now: today),
        throwsArgumentError,
      );

      final json = await BackupService(dao).exportJson();
      expect((await BackupService(restoredDao).importJson(json)).ok, isTrue);
      expect(
        decodeNavHistory((await restoredDao.getHolding(id))!.manualNavHistory),
        {'2026-11-17': 1.25, '2026-11-18': 1.3},
      );
      expect(await restoredDao.getTransactions(), isEmpty);
    },
  );

  test('holding sync preserves dates from concurrent bank observations', () {
    final local = <String, dynamic>{
      'id': 1,
      'assetType': 'bank_wealth',
      'currency': 'CNY',
      'updatedAt': '2026-11-18T10:00:00Z',
      'manualNavHistory': '{"2026-11-16":1.2,"2026-11-17":1.3}',
    };
    final remote = {
      ...local,
      'updatedAt': '2026-11-18T11:00:00Z',
      'manualNavHistory': '{"2026-11-17":1.4,"2026-11-18":1.5}',
    };
    final merged = SyncMerger().mergeTable(
      table: SyncTables.holdings,
      localRows: [local],
      remoteRows: [remote],
      tombstones: [],
    );
    expect(
      decodeNavHistory(merged.rows.single['manualNavHistory'] as String?),
      {'2026-11-16': 1.2, '2026-11-17': 1.4, '2026-11-18': 1.5},
    );
  });

  test(
    'fund source reads only published unit NAV in the requested date range',
    () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['FCODE'], '000001');
        return http.Response(
          jsonEncode({
            'ErrCode': 0,
            'Datas': [
              {'FSRQ': '2026-11-18', 'DWJZ': '1.21', 'LJJZ': '3.4'},
              {'FSRQ': '2026-11-17', 'DWJZ': '--'},
              {'FSRQ': '2026-11-16', 'DWJZ': '1.13'},
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      expect(
        await FundNavSource(
          client,
        ).fetch('000001', DateTime(2026, 11, 17), DateTime(2026, 11, 18)),
        {'2026-11-18': 1.21},
      );
    },
  );

  testWidgets('fund and bank details draw NAV without any transactions', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    final fund = await addHolding(dao, 'mutual_fund', code: '000001');
    final bank = await addHolding(dao, 'bank_wealth');
    final now = DateTime.now();
    await dao.recordManualNav(
      bank,
      now.subtract(const Duration(days: 2)),
      1.101,
    );
    await dao.recordManualNav(
      bank,
      now.subtract(const Duration(days: 1)),
      1.102,
    );
    final holdings = await dao.getHoldings();
    for (final id in [fund, bank]) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            holdingsProvider.overrideWith((ref) => Stream.value(holdings)),
            for (final id in [fund, bank])
              transactionsByHoldingProvider(
                id,
              ).overrideWith((ref) => Stream.value([])),
            priceCacheProvider.overrideWith((ref) async => {}),
            fundNavHistoryProvider('000001').overrideWith(
              (ref) async => {'2026-10-07': 1.1, '2026-10-08': 1.2},
            ),
          ],
          child: MaterialApp(
            home: HoldingKlinePage(key: ValueKey(id), holdingId: id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('单位净值走势'), findsOneWidget);
      final line = tester.widget<LineChart>(find.byType(LineChart));
      expect(line.data.lineBarsData.single.spots.length, 2);
      expect(find.text(id == bank ? '手工记录' : '天天基金'), findsOneWidget);
      expect(find.text('补录净值'), id == bank ? findsOneWidget : findsNothing);
    }
    expect(await dao.getTransactions(), isEmpty);
  });

  testWidgets('recording a bank NAV from its page updates the line', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    final bank = await addHolding(dao, 'bank_wealth');
    await dao.recordManualNav(
      bank,
      DateTime.now().subtract(const Duration(days: 1)),
      1.101,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          transactionsByHoldingProvider(
            bank,
          ).overrideWith((ref) => Stream.value([])),
          priceCacheProvider.overrideWith((ref) async => {}),
        ],
        child: MaterialApp(home: HoldingKlinePage(holdingId: bank)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LineChart), findsNothing);
    await tester.tap(find.text('补录净值'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1.1234');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(LineChart), findsOneWidget);
    expect((await dao.getHolding(bank))!.latestPrice, 1.1234);
    expect(await dao.getTransactions(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 350));
  });
}
