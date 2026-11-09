import 'dart:async';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/transaction_service.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('跨账户转账在双方显示一次，删除后两侧均更新', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    final service = TransactionService(dao);
    final sourceAccount = await dao.createAccount(
      AccountsCompanion.insert(name: '甲', type: 'general'),
    );
    final targetAccount = await dao.createAccount(
      AccountsCompanion.insert(name: '乙', type: 'general'),
    );
    Future<int> addCash(int account) => dao.createHolding(
      HoldingsCompanion.insert(
        accountId: account,
        name: '现金',
        assetType: AssetType.cash.storageName,
        quantity: const Value(100),
        costPrice: const Value(100),
      ),
    );
    final source = await addCash(sourceAccount);
    final target = await addCash(targetAccount);

    final destination = StreamIterator(
      dao.watchTransactionsByAccount(targetAccount),
    );
    addTearDown(destination.cancel);
    expect(await destination.moveNext(), isTrue);
    expect(destination.current, isEmpty);

    final result = await service.record(
      accountId: sourceAccount,
      type: TransactionType.transferOut,
      amount: 20,
      cashSourceId: source,
      cashTargetId: target,
    );
    expect(result.ok, isTrue);
    expect(await destination.moveNext(), isTrue);
    final transaction = destination.current.single;
    expect(
      (await dao.watchTransactionsByAccount(sourceAccount).first).single.id,
      transaction.id,
    );
    expect((await dao.getTransactions()).length, 1);

    expect((await service.remove(transaction.id)).ok, isTrue);
    expect(await destination.moveNext(), isTrue);
    expect(destination.current, isEmpty);
    expect(await dao.watchTransactionsByAccount(sourceAccount).first, isEmpty);
    expect((await dao.getHolding(source))!.quantity, 100);
    expect((await dao.getHolding(target))!.quantity, 100);
  });
}
