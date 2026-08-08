import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/responsive.dart';

/// Settings page. Backup/export lands in M5.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ResponsiveShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('备份与导出开发中 (M5)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('JSON / SQLite 导入导出即将上线'),
          ],
        ),
      ),
    );
  }
}
