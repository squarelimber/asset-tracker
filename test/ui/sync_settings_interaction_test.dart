import 'dart:convert';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/sync/sync_api.dart';
import 'package:asset_tracker/sync/sync_service.dart';
import 'package:asset_tracker/ui/pages/settings/sync_settings_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('saving and syncing sends requests to the visible server', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = AssetDao(db);
    await dao.setSetting(SyncSettingsKeys.serverUrl, 'https://old.example.test');
    final requests = <Uri>[];
    final service = SyncService(
      dao,
      apiFactory: (url, token) => SyncApi(
        url,
        token: token,
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode(request.method == 'GET'
                ? {'rev': 1, 'snapshot': {}, 'tombstones': []}
                : {'rev': 2}),
            200,
          );
        }),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(home: SyncSettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('立即同步'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'https://new.example.test');
    await tester.pumpAndSettle();
    expect(find.text('保存并同步'), findsOneWidget);
    await tester.tap(find.text('保存并同步'));
    await tester.pumpAndSettle();

    expect(requests.map((uri) => uri.host).toList(), ['new.example.test', 'new.example.test']);
    expect(await dao.getSetting(SyncSettingsKeys.serverUrl), 'https://new.example.test');
    expect(find.textContaining('已与 https://new.example.test 同步'), findsOneWidget);
    expect(find.textContaining('服务器版本 2'), findsOneWidget);
  });
}
