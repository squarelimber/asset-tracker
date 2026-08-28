import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../tokens.dart';

/// Bell (alerts, with 24h unread badge) + gear (settings) for page AppBars.
class TerminalAppBarActions extends ConsumerWidget {
  const TerminalAppBarActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(alertEventsProvider).value ?? const [];
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final unread =
        events.where((e) => e.triggeredAt.isAfter(cutoff)).length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '提醒',
          icon: Badge(
            isLabelVisible: unread > 0,
            label: Text('$unread'),
            backgroundColor: T.up,
            child: const Icon(Icons.notifications_outlined, color: T.text2),
          ),
          onPressed: () => context.go('/alerts'),
        ),
        IconButton(
          tooltip: '设置',
          icon: const Icon(Icons.settings_outlined, color: T.text2),
          onPressed: () => context.go('/settings'),
        ),
      ],
    );
  }
}
