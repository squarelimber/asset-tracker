import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';

class AssetTrackerApp extends ConsumerWidget {
  const AssetTrackerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Asset Tracker',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      routerConfig: router,
      builder: kIsWeb
          ? null
          : (context, child) => CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
                    router.routerDelegate.popRoute,
                const SingleActivator(LogicalKeyboardKey.browserBack):
                    router.routerDelegate.popRoute,
              },
              child: child!,
            ),
    );
  }
}
