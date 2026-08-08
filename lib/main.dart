import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'data/database.dart';
import 'services/data_migration_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase();
  await DataMigrationService(db).run();
  runApp(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const AssetTrackerApp(),
    ),
  );
}
