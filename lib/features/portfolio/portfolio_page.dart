import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/responsive.dart';

/// Portfolio dashboard. Full implementation lands in M3
/// (net worth curve, allocation pie, returns breakdown).
class PortfolioPage extends ConsumerWidget {
  const PortfolioPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('总览')),
      body: ResponsiveShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('仪表盘开发中 (M3)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('净值曲线 · 资产配置 · 收益统计即将上线'),
          ],
        ),
      ),
    );
  }
}
