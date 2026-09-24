import 'package:drift/drift.dart' hide Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/holdings/holding_dialogs.dart';

/// Host that opens the real add/edit holding dialogs.
class _Host extends ConsumerWidget {
  const _Host({this.holding});

  final HoldingRow? holding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () {
            final h = holding;
            if (h == null) {
              showAddHoldingDialog(context, ref);
            } else {
              showEditHoldingDialog(context, ref, h);
            }
          },
          child: Text(holding == null ? '添加持仓' : '编辑持仓'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('小屏（480 高）：添加持仓对话框首行「所属账户」不被顶部遮挡',
      (tester) async {
    tester.view.physicalSize = const Size(360, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'));

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: _Host()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加持仓'));
    await tester.pumpAndSettle();

    // 首字段「所属账户」必须可见且顶部完整落在屏幕内（上方无裁切）。
    expect(find.text('所属账户'), findsOneWidget,
        reason: '旧行为：对话框整体超高被顶出屏幕，首字段不可见');
    final top = tester.getTopLeft(find.text('所属账户')).dy;
    expect(top, greaterThanOrEqualTo(0),
        reason: '「所属账户」顶部应位于屏幕内（不超出上方被裁）');
    expect(top, lessThan(480 / 2),
        reason: '首字段应靠近对话框上部，而不是被挤到屏幕外');

    await db.close();
    await tester.pump();
  });

  testWidgets('小屏（480 高）：编辑持仓对话框首行「名称」不被顶部遮挡',
      (tester) async {
    tester.view.physicalSize = const Size(360, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final acc = await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: acc,
      name: '朝朝宝',
      assetType: 'savings',
      marketSource: const Value('manual'),
      quantity: const Value(83393),
      costPrice: const Value(83393),
      latestPrice: const Value(1),
    ));
    final holding = (await dao.getHoldings()).single;

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: _Host(holding: holding)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑持仓'));
    await tester.pumpAndSettle();

    expect(find.text('名称'), findsOneWidget);
    final top = tester.getTopLeft(find.text('名称')).dy;
    expect(top, greaterThanOrEqualTo(0),
        reason: '「名称」顶部应位于屏幕内（不超顶部被裁）');

    await db.close();
    await tester.pump();
  });
}