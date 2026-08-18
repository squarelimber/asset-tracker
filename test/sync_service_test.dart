import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/sync/sync_api.dart';
import 'package:asset_tracker/sync/sync_service.dart';

/// In-memory stand-in for the shelf sync server.
class _FakeServer {
  int rev = 0;
  Map<String, dynamic> snapshot = {};
  List<dynamic> tombstones = [];
  int putCount = 0;

  late final MockClient client = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/api/sync') {
      return http.Response(
        jsonEncode({'rev': rev, 'snapshot': snapshot, 'tombstones': tombstones}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.method == 'PUT' && request.url.path == '/api/sync') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      snapshot = (body['snapshot'] as Map<String, dynamic>?) ?? {};
      tombstones = (body['tombstones'] as List?) ?? const [];
      rev++;
      putCount++;
      return http.Response(jsonEncode({'rev': rev}), 200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('not found', 404);
  });
}

void main() {
  late AppDatabase db;
  late AssetDao dao;
  late _FakeServer server;
  late SyncService service;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
    server = _FakeServer();
    service = SyncService(
      dao,
      apiFactory: (url, token) => SyncApi(url, token: token, client: server.client),
    );
    await dao.setSetting(SyncSettingsKeys.serverUrl, 'http://fake:8787');
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedHolding({String name = '天天宝', double amount = 1000}) async {
    final accountId = await dao.createAccount(AccountsCompanion.insert(
      name: '账户',
      type: 'general',
    ));
    return dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: name,
      assetType: AssetType.bankDeposit.storageName,
      marketSource: const Value('manual'),
      quantity: Value(amount),
      costPrice: Value(amount),
      latestPrice: const Value(1),
      purchaseDate: Value(DateTime(2026, 1, 1)),
    ));
  }

  test('first sync pushes the local data and stores the revision', () async {
    await seedHolding();

    final result = await service.sync();

    expect(result.ok, isTrue);
    expect(result.rev, 1);
    expect(result.conflicts, 0);
    expect(result.changed, 0); // nothing changed locally
    expect(server.putCount, 1);
    final holdings = server.snapshot['holdings'] as List;
    expect(holdings, hasLength(1));
    expect(await dao.getSetting(SyncSettingsKeys.lastRev), '1');
  });

  test('remote rows are pulled into an empty local database', () async {
    // Seed the server from another device first.
    final serverDb = AppDatabase(NativeDatabase.memory());
    final serverDao = AssetDao(serverDb);
    await serverDao.setSetting(SyncSettingsKeys.serverUrl, 'http://fake:8787');
    final otherService = SyncService(
      serverDao,
      apiFactory: (url, token) => SyncApi(url, token: token, client: server.client),
    );
    final accountId = await serverDao.createAccount(AccountsCompanion.insert(
      name: '远端账户',
      type: 'general',
    ));
    await serverDao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '远端基金',
      assetType: AssetType.mutualFund.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(100),
      costPrice: const Value(2.5),
      latestPrice: const Value(2.6),
      purchaseDate: Value(DateTime(2026, 1, 1)),
    ));
    await otherService.sync();
    await serverDb.close();

    final result = await service.sync();

    expect(result.ok, isTrue);
    final holdings = await dao.getHoldings();
    expect(holdings, hasLength(1));
    expect(holdings.single.name, '远端基金');
    final accounts = await dao.getAccounts();
    expect(accounts.single.name, '远端账户');
  });

  test('deletion on one device does not resurrect on another', () async {
    final holdingId = await seedHolding(name: '要删除的');

    // Device A syncs and deletes.
    await service.sync();
    await dao.deleteHolding(holdingId);
    final deleteResult = await service.sync();
    expect(deleteResult.ok, isTrue);
    expect(server.tombstones, isNotEmpty);

    // Device B (fresh local) syncs twice: first pull creates the row
    // ... actually the tombstone should win on the FIRST sync too.
    final dbB = AppDatabase(NativeDatabase.memory());
    final daoB = AssetDao(dbB);
    await daoB.setSetting(SyncSettingsKeys.serverUrl, 'http://fake:8787');
    final serviceB = SyncService(
      daoB,
      apiFactory: (url, token) => SyncApi(url, token: token, client: server.client),
    );
    await serviceB.sync();
    expect(await daoB.getHoldings(), isEmpty);
    await dbB.close();
  });

  test('conflicting edits on both devices are resolved by LWW', () async {
    final holdingId = await seedHolding(name: '原名', amount: 1000);
    await service.sync();
    final now = DateTime.now();

    // Device A changes the amount (newer).
    final h = (await dao.getHolding(holdingId))!;
    await dao.updateHolding(
      HoldingRow(
        id: h.id,
        accountId: h.accountId,
        name: h.name,
        assetType: h.assetType,
        marketSource: h.marketSource,
        symbol: h.symbol,
        quantity: 2000,
        costPrice: h.costPrice,
        latestPrice: h.latestPrice,
        costFxRate: h.costFxRate,
        purchaseDate: h.purchaseDate,
        riskLevel: h.riskLevel,
        currency: h.currency,
        note: h.note,
        createdAt: h.createdAt,
        updatedAt: now,
      ),
      now: now,
    );

    // Device B (with an older copy) changes the name (older).
    final dbB = AppDatabase(NativeDatabase.memory());
    final daoB = AssetDao(dbB);
    await daoB.setSetting(SyncSettingsKeys.serverUrl, 'http://fake:8787');
    final serviceB = SyncService(
      daoB,
      apiFactory: (url, token) => SyncApi(url, token: token, client: server.client),
    );
    await serviceB.sync(); // pulls the original row
    final hB = (await daoB.getHolding(holdingId))!;
    final older = now.subtract(const Duration(hours: 2));
    await daoB.updateHolding(
      HoldingRow(
        id: hB.id,
        accountId: hB.accountId,
        name: hB.name,
        assetType: hB.assetType,
        marketSource: hB.marketSource,
        symbol: hB.symbol,
        quantity: hB.quantity,
        costPrice: hB.costPrice,
        latestPrice: hB.latestPrice,
        costFxRate: hB.costFxRate,
        purchaseDate: hB.purchaseDate,
        riskLevel: hB.riskLevel,
        currency: hB.currency,
        note: hB.note,
        createdAt: hB.createdAt,
        updatedAt: older,
      ),
      now: older,
    );

    // Device A syncs its newer edit up.
    final rA = await service.sync();
    expect(rA.ok, isTrue);

    // Device B syncs: its older edit loses, the newer amount wins.
    final rB = await serviceB.sync();
    expect(rB.ok, isTrue);
    expect(rB.conflicts, greaterThan(0));
    final merged = (await daoB.getHolding(holdingId))!;
    expect(merged.quantity, 2000);
    expect(merged.name, '原名');
    await dbB.close();
  });

  test('sync fails when no server URL is configured', () async {
    await dao.setSetting(SyncSettingsKeys.serverUrl, '');
    final result = await service.sync();
    expect(result.ok, isFalse);
    expect(result.message, contains('未配置'));
  });
}
