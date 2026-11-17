import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/ui_prefs.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/settings/settings_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('startup visibility preference persists independently of the eye toggle',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      hideAmountsProvider.overrideWith((ref) => false),
    ]);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsPage()),
    ));
    await tester.pumpAndSettle();
    final title = find.text('启动时隐藏金额');
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    final switchFinder = find.descendant(
      of: find.ancestor(of: title, matching: find.byType(Row)).first,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(switchFinder).value, false);
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(await dao.getSetting(hideAmountsOnStartupKey), 'true');
    expect(container.read(hideAmountsProvider), isTrue);

    container.read(hideAmountsProvider.notifier).state = false;
    await tester.pump();
    expect(await dao.getSetting(hideAmountsOnStartupKey), 'true');
    expect(tester.widget<Switch>(switchFinder).value, true);
  });
}
