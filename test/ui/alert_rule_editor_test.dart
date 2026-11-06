import 'dart:convert';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/ui/pages/alerts/alert_rule_editor.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_page.dart'
    show summaryProvider;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('new equity rule follows allocation target by default', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        summaryProvider.overrideWith(
          (ref) async => const PortfolioSummary(
            totalAssets: 0,
            totalLiabilities: 0,
            totalCost: 0,
            todayChange: 0,
            todayChangePct: null,
            breakdown: [],
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAlertRuleEditor(context),
                child: const Text('添加'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<AlertRuleType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置比例偏离').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(find.textContaining('不会同步此目标'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    final rule = (await container.read(daoProvider).getAlertRules()).single;
    expect(jsonDecode(rule.params)['followTarget'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing a legacy rule keeps exact thresholds and custom mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        summaryProvider.overrideWith(
          (ref) async => const PortfolioSummary(
            totalAssets: 0,
            totalLiabilities: 0,
            totalCost: 0,
            todayChange: 0,
            todayChangePct: null,
            breakdown: [],
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final dao = container.read(daoProvider);
    await dao.createAlertRule(
      AlertRulesCompanion.insert(
        type: 'asset_ratio',
        name: '旧规则',
        params: Value(
          jsonEncode({
            'target': .123456789,
            'tolerance': .03456789,
            'futureKey': 'keep',
          }),
        ),
      ),
    );
    final rule = (await dao.getAlertRules()).single;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAlertRuleEditor(context, rule: rule),
                child: const Text('编辑'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '规则名称（可选）'),
      '仅修改名称',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    final saved = (await dao.getAlertRules()).single;
    final params = jsonDecode(saved.params) as Map<String, dynamic>;
    expect(saved.name, '仅修改名称');
    expect(params['target'], .123456789);
    expect(params['tolerance'], .03456789);
    expect(params['followTarget'], isFalse);
    expect(params['futureKey'], 'keep');
    expect(tester.takeException(), isNull);
  });
}
