import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/responsive.dart';

/// Alert rules page. Full implementation lands in M4 (rule engine).
class AlertsPage extends ConsumerWidget {
  const AlertsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('提醒')),
      body: ResponsiveShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('规则引擎开发中 (M4)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('集中度风险 · 配置比例 · 跌幅预警 · 现金流提醒即将上线'),
          ],
        ),
      ),
    );
  }
}
