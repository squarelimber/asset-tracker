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
  final db = AppDatabase();
  await DataMigrationService(db).run();
  await _autoSyncIfConfigured(AssetDao(db));
  runApp(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const AssetTrackerApp(),
    ),
  );
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
