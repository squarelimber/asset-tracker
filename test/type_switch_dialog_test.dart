import 'package:drift/drift.dart' hide Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/holdings/holding_dialogs.dart';

/// Host that opens the real edit-holding dialog, driving the save branch end
/// to end (conversion + persistence + full-rebuild marker).
class _EditHost extends ConsumerWidget {
  const _EditHost(this.holding);

  final HoldingRow holding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => showEditHoldingDialog(context, ref, holding),
          child: const Text('编辑'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
      '编辑对话框：银行存款→银行理财 自动换算字段并设置全量重建标记',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final accId = await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accId,
      name: '朝朝宝',
      assetType: AssetType.bankDeposit.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(50000),
      costPrice: const Value(50000),
      latestPrice: const Value(1),
    ));
    final holding = (await dao.getHoldings()).single;

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: _EditHost(holding)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    // 打开「资产类型」下拉框，选择 银行理财。
    await tester.tap(find.byType(DropdownButtonFormField<AssetType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('银行理财').last);
    await tester.pumpAndSettle();

    // 跨金额性切换：字段被自动换算。
    expect(
      find.textContaining('已按「银行理财」口径自动换算'),
      findsOneWidget,
      reason: '旧行为：数字原样保留，成本单价仍是累计投入 50000',
    );
    final costField = tester.widget<TextField>(
      find.widgetWithText(TextField, '成本单价'),
    );
    expect(costField.controller!.text, '1',
        reason: '累计投入 50000 ÷ 份额 50000 → 单位成本 1');
    final qtyField = tester.widget<TextField>(
      find.widgetWithText(TextField, '数量 / 份额 / 克数'),
    );
    expect(qtyField.controller!.text, '50000');
    final priceField = tester.widget<TextField>(
      find.widgetWithText(TextField, '最新单价'),
    );
    expect(priceField.controller!.text, '1'); // 净值占位，用户填真实值

    // 保存：数字按新语义落库，并标记全量重建。
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    final saved = (await dao.getHoldings()).single;
    expect(saved.assetType, AssetType.bankWealth.storageName);
    expect(saved.quantity, closeTo(50000, 1e-9)); // 份额
    expect(saved.costPrice, closeTo(1, 1e-9)); // 单位成本 —— 旧行为是 50000
    expect(saved.latestPrice, closeTo(1, 1e-9)); // 净值占位
    expect(await dao.getSetting('history_full_rebuild'), '1',
        reason: '类型跨越金额性，必须全量重算历史');
    expect(await dao.getSetting('history_sync_dirty'), '1');

    // Close the DB inside the test body so drift's stream-query timers are
    // cancelled before the "no pending timers" invariant is checked.
    await db.close();
    await tester.pump();
  });

  testWidgets(
      '编辑对话框：银行理财→现金 自动换算为余额与累计投入',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final accId = await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accId,
      name: '朝朝宝',
      assetType: AssetType.bankWealth.storageName,
      marketSource: const Value('manual'),
      quantity: const Value(1000), // 份额
      costPrice: const Value(1.5), // 单位成本
      latestPrice: const Value(1.1), // 净值
    ));
    final holding = (await dao.getHoldings()).single;

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: _EditHost(holding)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<AssetType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('现金').last);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('已按「现金」口径自动换算'),
      findsOneWidget,
    );
    // 金额型弹出「当前金额 / 累计投入」联动字段。
    final amountField = tester.widget<TextField>(
      find.widgetWithText(TextField, '当前金额'),
    );
    expect(amountField.controller!.text, '1100',
        reason: '份额 1000 × 净值 1.1 → 余额 1100');
    final investedField = tester.widget<TextField>(
      find.widgetWithText(TextField, '累计投入'),
    );
    expect(investedField.controller!.text, '1500',
        reason: '份额 1000 × 单位成本 1.5 → 累计投入 1500');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    final saved = (await dao.getHoldings()).single;
    expect(saved.assetType, AssetType.cash.storageName);
    expect(saved.quantity, closeTo(1100, 1e-9)); // 余额（市值）
    expect(saved.costPrice, closeTo(1500, 1e-9)); // 累计投入（成本）
    expect(saved.latestPrice, closeTo(1, 1e-9));
    // 收益保留：1100 − 1500 = −400（与切换前 1000×1.1 − 1000×1.5 一致）。
    expect(await dao.getSetting('history_full_rebuild'), '1');

    await db.close();
    await tester.pump();
  });
}