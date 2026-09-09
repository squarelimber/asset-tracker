import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive.dart';
import '../components/key_shortcuts.dart';
import '../tokens.dart';

/// App shell with adaptive navigation:
/// - Phone: bottom navigation bar
/// - Desktop: side navigation rail
class ShellPage extends StatelessWidget {
  const ShellPage({super.key, required this.child});

  final Widget child;

  static const _destinations = [
    (icon: Icons.donut_large_outlined, activeIcon: Icons.donut_large, label: '总览', path: '/portfolio'),
    (icon: Icons.pie_chart_outline, activeIcon: Icons.pie_chart, label: '持仓', path: '/holdings'),
    (icon: Icons.account_balance_wallet_outlined, activeIcon: Icons.account_balance_wallet, label: '账户', path: '/accounts'),
    (icon: Icons.candlestick_chart_outlined, activeIcon: Icons.candlestick_chart, label: '行情', path: '/markets'),
    (icon: Icons.assessment_outlined, activeIcon: Icons.assessment, label: '统计', path: '/stats'),
  ];

  /// Shell-level routes that live inside the [ShellRoute] and are navigated
  /// via [GoRouter.go].  Android back gesture on these pages should navigate
  /// back to the root page (/portfolio) rather than exiting the app.
  static final _shellPaths = {
    for (final d in _destinations) d.path,
    '/transactions',
    '/alerts',
    '/settings',
  };

  @override
  Widget build(BuildContext context) {
    // Determine whether the current route is a shell-level page (no stack to
    // pop) or a pushed route (e.g. /earnings-calendar, /accounts/:id) that
    // has a proper back stack.
    final currentPath = GoRouterState.of(context).uri.path;
    final canPop = !_shellPaths.any((p) => currentPath.startsWith(p));

    Widget child = _shellBody(context);
    child = PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && context.mounted) {
          context.go('/portfolio');
        }
      },
      child: child,
    );
    return child;
  }

  Widget _shellBody(BuildContext context) {
    if (!Responsive.isDesktop(context)) return _PhoneShell(child: child);
    // Desktop keyboard shortcuts: 1-6 switch the main pages + history.
    return KeyShortcuts(
      onKeyDown: (key) {
        final i = switch (key) {
          LogicalKeyboardKey.digit1 => 0,
          LogicalKeyboardKey.digit2 => 1,
          LogicalKeyboardKey.digit3 => 2,
          LogicalKeyboardKey.digit4 => 3,
          LogicalKeyboardKey.digit5 => 4,
          LogicalKeyboardKey.digit6 => -2,
          _ => -1,
        };
        if (i >= 0) {
          context.go(_destinations[i].path);
        } else if (i == -2) {
          context.go('/transactions');
        }
      },
      child: _DesktopShell(child: child),
    );
  }
}

class _PhoneShell extends StatelessWidget {
  const _PhoneShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex(context),
        onDestinationSelected: (i) => context.go(ShellPage._destinations[i].path),
        destinations: [
          for (final d in ShellPage._destinations)
            NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.activeIcon), label: d.label),
        ],
      ),
    );
  }

  int _selectedIndex(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    final i = ShellPage._destinations.indexWhere((d) => path.startsWith(d.path));
    return i < 0 ? 0 : i;
  }
}

/// A highlighted icon+label action pinned to the bottom of the desktop rail
/// (secondary pages that do not belong in the main tab list).
class _RailAction extends StatelessWidget {
  const _RailAction({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? T.text1 : T.text2;
    return InkWell(
      borderRadius: BorderRadius.circular(T.rCard),
      onTap: onTap,
      child: Container(
        width: 56,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? T.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(T.rCard),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selected ? activeIcon : icon, size: 22, color: fg),
            const SizedBox(height: 4),
            Text(label, style: T.label(size: 11, color: fg)),
          ],
        ),
      ),
    );
  }
}

class _DesktopShell extends StatelessWidget {
  const _DesktopShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final selected = _selectedIndex(context);
    final path = GoRouterState.of(context).uri.path;
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: selected,
            onDestinationSelected: (i) =>
                context.go(ShellPage._destinations[i].path),
            labelType: NavigationRailLabelType.all,
            trailing: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: T.s2),
                _RailAction(
                  icon: Icons.receipt_long_outlined,
                  activeIcon: Icons.receipt_long,
                  label: '流水',
                  selected: path.startsWith('/transactions'),
                  onTap: () => context.go('/transactions'),
                ),
                const SizedBox(height: T.s1),
                _RailAction(
                  icon: Icons.notifications_outlined,
                  activeIcon: Icons.notifications,
                  label: '提醒',
                  selected: path.startsWith('/alerts'),
                  onTap: () => context.go('/alerts'),
                ),
                const SizedBox(height: T.s1),
                _RailAction(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings,
                  label: '设置',
                  selected: path.startsWith('/settings'),
                  onTap: () => context.go('/settings'),
                ),
              ],
            ),
            destinations: [
              for (final d in ShellPage._destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.activeIcon),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: child),
        ],
      ),
    );
  }

  int _selectedIndex(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    final i = ShellPage._destinations.indexWhere((d) => path.startsWith(d.path));
    return i < 0 ? 0 : i;
  }
}
