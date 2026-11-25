import 'dart:convert';

import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/services/backup_service.dart';
import 'package:asset_tracker/sync/sync_api.dart';
import 'package:asset_tracker/sync/sync_format.dart';
import 'package:asset_tracker/sync/sync_service.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _target = (url: 'http://snapshot-test:8787', token: null as String?);

class _MemoryServer {
  int rev = 0;
  Map<String, dynamic> snapshot = {};

  MockClient client() => MockClient((request) async {
    if (request.method == 'GET') {
      return http.Response(
        jsonEncode({'rev': rev, 'snapshot': snapshot, 'tombstones': []}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (body['baseRev'] != rev) {
      return http.Response(
        jsonEncode({'rev': rev}),
        409,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    snapshot = body['snapshot'] as Map<String, dynamic>;
    return http.Response(
      jsonEncode({'rev': ++rev}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  SyncService service(AssetDao dao) => SyncService(
    dao,
    apiFactory: (url, token) => SyncApi(url, token: token, client: client()),
  );
}

Future<void> _seed(AssetDao dao) async {
  final at = DateTime(2026, 11, 1, 16);
  await dao.createAccount(
    AccountsCompanion.insert(
      id: const Value(1),
      name: '演示账户',
      type: 'general',
      createdAt: Value(at),
      updatedAt: Value(at),
    ),
  );
  await dao.createHolding(
    HoldingsCompanion.insert(
      id: const Value(101),
      accountId: 1,
      name: '演示现金',
      assetType: 'cash',
      quantity: const Value(112),
      costPrice: const Value(100),
      costRecorded: const Value(true),
      latestPrice: const Value(1),
      createdAt: Value(at),
      updatedAt: Value(at),
    ),
  );
  for (var index = 0; index < 3; index++) {
    final adjustment = <double?>[null, 0, -3.5][index];
    final value = 110.0 + index;
    await dao.upsertSnapshot(
      SnapshotsCompanion.insert(
        date: '2026-11-0${index + 1}',
        totalValue: value,
        totalCost: 100,
        realizedProfit: const Value(4.25),
        profitAdjustment: Value(adjustment),
        holdingValues: Value(
          encodeHoldingValues([
            DayHoldingValue(
              holdingId: 101,
              name: '演示现金',
              type: AssetType.cash,
              value: value,
              cost: 100,
              liability: false,
              realizedProfit: 4.25,
              profitAdjustment: adjustment ?? 0,
            ),
          ]),
        ),
        createdAt: Value(at.add(Duration(days: index))),
      ),
    );
  }
}

void main() {
  test(
    'schema 17 snapshots gain a nullable adjustment without changing money',
    () async {
      final db = AppDatabase(
        NativeDatabase.memory(
          setup: (sqlite) {
            sqlite.execute(
              'CREATE TABLE snapshots ('
              'date TEXT NOT NULL, currency TEXT NOT NULL, total_value REAL NOT NULL, '
              'total_cost REAL NOT NULL, liabilities REAL NOT NULL, '
              'holding_values TEXT, realized_profit REAL, created_at INTEGER NOT NULL, '
              'PRIMARY KEY (date, currency))',
            );
            sqlite.execute(
              "INSERT INTO snapshots VALUES ('2026-11-01', 'CNY', 128, 100, 0, NULL, 4.25, 1)",
            );
            sqlite.execute('PRAGMA user_version = 17');
          },
        ),
      );
      addTearDown(db.close);
      final dao = AssetDao(db);
      final snapshot = (await dao.getSnapshots()).single;
      expect(snapshot.totalValue, 128);
      expect(snapshot.totalCost, 100);
      expect(snapshot.realizedProfit, 4.25);
      expect(snapshot.profitAdjustment, isNull);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data.values.single, db.schemaVersion);
      final columns = await db
          .customSelect('PRAGMA table_info(snapshots)')
          .get();
      expect(
        columns.map((row) => row.read<String>('name')),
        contains('profit_adjustment'),
      );
      await dao.upsertSnapshot(
        snapshot.copyWith(profitAdjustment: const Value(0)).toCompanion(true),
      );
      expect((await dao.getSnapshots()).single.profitAdjustment, 0);
    },
  );

  test(
    'sync formatter distinguishes missing, zero and nonzero adjustments',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = AssetDao(db);
      await _seed(dao);
      const formatter = SyncFormatter();
      final rows = (await dao.getSnapshots())
          .map(formatter.snapshotToRow)
          .toList();
      expect(rows[0].containsKey('profitAdjustment'), isFalse);
      expect(rows[1]['profitAdjustment'], 0);
      expect(rows[2]['profitAdjustment'], -3.5);
      expect(rows.map((row) => row['realizedProfit']), everyElement(4.25));
      final decoded = jsonDecode(jsonEncode(rows)) as List;
      expect(decoded[1]['profitAdjustment'], 0);
      expect(decoded[2]['profitAdjustment'], -3.5);
    },
  );

  test(
    'backup roundtrip preserves both aggregate and per-holding adjustments',
    () async {
      final sourceDb = AppDatabase(NativeDatabase.memory());
      final destinationDb = AppDatabase(NativeDatabase.memory());
      addTearDown(sourceDb.close);
      addTearDown(destinationDb.close);
      final source = AssetDao(sourceDb);
      final destination = AssetDao(destinationDb);
      await _seed(source);
      final payload = await BackupService(source).exportJson();
      final exported = (jsonDecode(payload) as Map)['snapshots'] as List;
      expect((exported[0] as Map).containsKey('profitAdjustment'), isFalse);
      expect(exported[1]['profitAdjustment'], 0);
      expect(exported[2]['profitAdjustment'], -3.5);
      final result = await BackupService(destination).importJson(payload);
      expect(result.ok, isTrue, reason: result.message);
      expect(await destination.getSnapshots(), await source.getSnapshots());
      final originalHolding = (await source.getHoldings()).single;
      final restoredHolding = (await destination.getHoldings()).single;
      expect(restoredHolding.quantity, originalHolding.quantity);
      expect(restoredHolding.costPrice, originalHolding.costPrice);
      expect(restoredHolding.costRecorded, originalHolding.costRecorded);
    },
  );

  for (final explicitNull in [false, true]) {
    test(
      'legacy backup clears cached adjustments (explicit null: $explicitNull)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final dao = AssetDao(db);
        await _seed(dao);
        final backup =
            jsonDecode(await BackupService(dao).exportJson())
                as Map<String, dynamic>;
        for (final row in backup['snapshots'] as List) {
          final map = row as Map<String, dynamic>;
          if (explicitNull) {
            map['profitAdjustment'] = null;
          } else {
            map.remove('profitAdjustment');
          }
          // A legacy peer has no per-holding adjustment either.
          final detail = jsonDecode(map['holdingValues'] as String) as List;
          for (final holding in detail) {
            (holding as Map).remove('profitAdjustment');
          }
          map['holdingValues'] = jsonEncode(detail);
        }
        final result = await BackupService(dao).importJson(jsonEncode(backup));
        expect(result.ok, isTrue, reason: result.message);
        final snapshots = await dao.getSnapshots();
        expect(
          snapshots.map((row) => row.profitAdjustment),
          everyElement(isNull),
        );
        expect(snapshots.map((row) => row.realizedProfit), everyElement(4.25));
        expect(snapshots.map((row) => row.totalValue), [110, 111, 112]);
      },
    );
  }

  test(
    'sync merge roundtrip keeps null, zero and nonzero values on both devices',
    () async {
      final firstDb = AppDatabase(NativeDatabase.memory());
      final secondDb = AppDatabase(NativeDatabase.memory());
      addTearDown(firstDb.close);
      addTearDown(secondDb.close);
      final first = AssetDao(firstDb);
      final second = AssetDao(secondDb);
      await _seed(first);
      final server = _MemoryServer();
      final firstResult = await server.service(first).sync(target: _target);
      expect(firstResult.ok, isTrue, reason: firstResult.message);
      final secondResult = await server.service(second).sync(target: _target);
      expect(secondResult.ok, isTrue, reason: secondResult.message);
      expect(await second.getSnapshots(), await first.getSnapshots());
      final wireRows = server.snapshot['snapshots'] as List;
      expect((wireRows[0] as Map).containsKey('profitAdjustment'), isFalse);
      expect(wireRows[1]['profitAdjustment'], 0);
      expect(wireRows[2]['profitAdjustment'], -3.5);
    },
  );

  for (final explicitNull in [false, true]) {
    test(
      'newer legacy sync snapshot clears the old adjustment (explicit null: $explicitNull)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final dao = AssetDao(db);
        await _seed(dao);
        final server = _MemoryServer();
        expect((await server.service(dao).sync(target: _target)).ok, isTrue);
        final rows = server.snapshot['snapshots'] as List;
        final changed = rows.last as Map<String, dynamic>;
        if (explicitNull) {
          changed['profitAdjustment'] = null;
        } else {
          changed.remove('profitAdjustment');
        }
        changed['holdingValues'] = null;
        changed['createdAt'] = '2026-11-04T16:00:00.000';
        changed['updatedAt'] = changed['createdAt'];
        server.rev++;
        final result = await server.service(dao).sync(target: _target);
        expect(result.ok, isTrue, reason: result.message);
        final restored = (await dao.getSnapshots()).last;
        expect(restored.profitAdjustment, isNull);
        expect(restored.holdingValues, isNull);
        expect(restored.realizedProfit, 4.25);
        expect(restored.totalValue, 112);
        expect(restored.totalCost, 100);
        final uploaded = (server.snapshot['snapshots'] as List).last as Map;
        expect(uploaded['profitAdjustment'], isNull);
      },
    );
  }
}
