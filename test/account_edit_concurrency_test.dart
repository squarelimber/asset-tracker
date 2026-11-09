import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('编辑名称和备注保留编辑期间同步的账户类型和币种', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    final id = await dao.createAccount(
      AccountsCompanion.insert(name: '旧名称', type: 'general'),
    );
    final openedAccount = (await dao.getAccount(id))!;
    await dao.updateAccount(
      openedAccount.copyWith(type: 'bank', currency: 'USD'),
    );

    await dao.updateAccountDetails(id, name: '新名称', note: '新备注');
    final saved = (await dao.getAccount(id))!;
    expect(saved.name, '新名称');
    expect(saved.note, '新备注');
    expect(saved.type, 'bank');
    expect(saved.currency, 'USD');

    await dao.updateAccountDetails(id, name: '新名称', note: null);
    final cleared = (await dao.getAccount(id))!;
    expect(cleared.note, isNull);
    expect(cleared.type, 'bank');
    expect(cleared.currency, 'USD');
  });
}
