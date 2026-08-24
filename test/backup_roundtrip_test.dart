import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/backup_service.dart';

void main() {
  late AppDatabase db;
  late AssetDao dao;
  late BackupService service;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
    service = BackupService(dao);
  });

  tearDown(() async {
    await db.close();
  });

  test('round-trip preserves original ids and transfer links', () async {
    // Simulate a database with id holes: account 1 deleted, holding 3
    // deleted, so auto-increment ids do not line up with insertion order.
    await dao.createAccount(AccountsCompanion.insert(
      id: const Value(2),
      name: '支付宝',
      type: 'general',
    ));
    await dao.createAccount(AccountsCompanion.insert(
      id: const Value(6),
      name: '京东金融',
      type: 'general',
    ));
    await dao.createHolding(HoldingsCompanion.insert(
      id: const Value(4),
      accountId: 2,
      name: '余额宝',
      assetType: 'bank_deposit',
      quantity: const Value(7121),
      costPrice: const Value(6212),
      latestPrice: const Value(1),
    ));
    final cash = await dao.createHolding(HoldingsCompanion.insert(
      id: const Value(15),
      accountId: 6,
      name: '天天宝',
      assetType: 'liquid_wealth',
      quantity: const Value(96071),
      costPrice: const Value(96071),
      latestPrice: const Value(1),
    ));
    final card = await dao.createHolding(HoldingsCompanion.insert(
      id: const Value(27),
      accountId: 6,
      name: '万事达',
      assetType: 'liability',
      quantity: const Value(181),
      costPrice: const Value(1),
      latestPrice: const Value(1),
    ));
    await dao.createTransaction(TransactionsCompanion.insert(
      id: const Value(3),
      accountId: 6,
      type: 'transfer_out',
      amount: 181.16,
      cashSourceId: Value(cash),
      cashTargetId: Value(card),
      occurredAt: DateTime(2026, 8, 1),
      costMoved: const Value(false),
    ));

    final json = await service.exportJson();

    // Fresh database on "another device".
    final db2 = AppDatabase(NativeDatabase.memory());
    addTearDown(db2.close);
    final dao2 = AssetDao(db2);
    final result = await BackupService(dao2).importJson(json);

    expect(result.ok, isTrue, reason: result.message);
    final accounts = await dao2.getAccounts();
    expect(accounts.map((a) => a.id).toSet(), {2, 6}); // original ids kept
    final holdings = await dao2.getHoldings();
    expect(holdings.map((h) => h.id).toSet(), {4, 15, 27});
    final yebao = holdings.firstWhere((h) => h.name == '余额宝');
    expect(yebao.accountId, 2); // linked to the right account
    final txns = await dao2.getTransactions();
    expect(txns, hasLength(1));
    final t = txns.single;
    expect(t.id, 3);
    expect(t.cashSourceId, 15); // transfer links preserved
    expect(t.cashTargetId, 27);
    expect(t.costMoved, isFalse);
  });

  test('import rejects backups with dangling references', () async {
    final broken = jsonEncode({
      'app': 'asset_tracker',
      'version': 2,
      'accounts': [
        {'id': 1, 'name': '账户', 'type': 'general', 'currency': 'CNY'},
      ],
      'holdings': [
        {
          'id': 10,
          'accountId': 99, // does not exist in the backup
          'name': '孤儿持仓',
          'assetType': 'savings',
          'marketSource': 'manual',
          'quantity': 1,
          'costPrice': 1,
          'latestPrice': 1,
          'currency': 'CNY',
        },
      ],
      'transactions': [
        {
          'id': 20,
          'accountId': 1,
          'holdingId': 42, // does not exist in the backup
          'type': 'buy',
          'amount': 10,
          'currency': 'CNY',
          'occurredAt': '2026-08-01T10:00:00',
        },
      ],
      'snapshots': const [],
      'alertRules': const [],
    });

    final result = await service.importJson(broken);

    expect(result.ok, isFalse);
    expect(result.message, contains('不存在'));
    expect(await dao.getAccounts(), isEmpty);
    expect(await dao.getHoldings(), isEmpty);
    expect(await dao.getTransactions(), isEmpty);
  });

  test('legacy backups without id fields still import', () async {
    final legacy = jsonEncode({
      'app': 'asset_tracker',
      'version': 1,
      'accounts': [
        {'name': '旧账户', 'type': 'general', 'currency': 'CNY'},
      ],
      'holdings': [
        {
          'accountId': 1,
          'name': '旧持仓',
          'assetType': 'savings',
          'marketSource': 'manual',
          'quantity': 1000,
          'costPrice': 1000,
          'latestPrice': 1,
          'currency': 'CNY',
        },
      ],
      'transactions': [
        {
          'accountId': 1,
          'type': 'income',
          'amount': 500,
          'currency': 'CNY',
          'occurredAt': '2026-08-01T10:00:00',
        },
      ],
      'snapshots': const [],
      'alertRules': const [],
    });

    final result = await service.importJson(legacy);

    expect(result.ok, isTrue, reason: result.message);
    final accounts = await dao.getAccounts();
    expect(accounts, hasLength(1));
    final holdings = await dao.getHoldings();
    expect(holdings, hasLength(1));
    expect(holdings.single.accountId, accounts.single.id); // auto-increment
    expect(await dao.getTransactions(), hasLength(1));
  });
}
