import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/responsive.dart';
import '../tokens.dart';

/// Receipt (history) + bell (alerts, with 24h unread badge) + gear
/// (settings) for page AppBars.
class TerminalAppBarActions extends ConsumerWidget {
  const TerminalAppBarActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Desktop secondary destinations already live in the persistent sidebar.
    if (Responsive.isDesktop(context)) return const SizedBox.shrink();
    final currentPath = GoRouter.maybeOf(context) == null
        ? null
        : GoRouterState.of(context).uri.path;
    final events = ref.watch(alertEventsProvider).value ?? const [];
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final unread = events.where((e) => e.triggeredAt.isAfter(cutoff)).length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (currentPath != '/transactions')
          IconButton(
            tooltip: '交易流水',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => context.push('/transactions'),
          ),
        if (currentPath != '/alerts')
          IconButton(
            tooltip: '提醒',
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              backgroundColor: T.up,
              child: const Icon(Icons.notifications_outlined),
            ),
            onPressed: () => context.push('/alerts'),
          ),
        if (currentPath != '/settings')
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
      ],
    );
  }
}
