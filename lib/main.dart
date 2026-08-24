import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'data/asset_dao.dart';
import 'data/database.dart';
import 'services/data_migration_service.dart';
import 'sync/sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppDatabase db;
  try {
    db = AppDatabase();
    await DataMigrationService(db).run();
  } catch (e) {
    // A corrupt or unreadable database must not leave a dead app: show a
    // recoverable error screen instead of crashing before the first frame.
    runApp(_FatalStartupErrorApp(error: e));
    return;
  }
  await _autoSyncIfConfigured(AssetDao(db));
  runApp(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const AssetTrackerApp(),
    ),
  );
}

/// Minimal error screen shown when the database cannot be opened or
/// migrated. The user can clear app data to start fresh.
class _FatalStartupErrorApp extends StatelessWidget {
  const _FatalStartupErrorApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(
              '数据库初始化失败：$error\n\n'
              '如果问题持续，请清除应用数据后重试（会丢失本地未同步的数据）。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

/// Background silent sync on startup when enabled in the sync settings.
/// Runs detached so a slow server never blocks the UI.
Future<void> _autoSyncIfConfigured(AssetDao dao) async {
  try {
    final auto = await dao.getSetting(SyncSettingsKeys.autoSync);
    if (auto != 'true') return;
    unawaited(SyncService(dao).sync());
  } catch (_) {
    // Startup must never fail because of sync configuration.
  }
}
