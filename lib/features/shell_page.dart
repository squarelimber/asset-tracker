import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/responsive.dart';

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
    (icon: Icons.notifications_outlined, activeIcon: Icons.notifications, label: '提醒', path: '/alerts'),
    (icon: Icons.settings_outlined, activeIcon: Icons.settings, label: '设置', path: '/settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return Responsive.isDesktop(context)
        ? _DesktopShell(child: child)
        : _PhoneShell(child: child);
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

class _DesktopShell extends StatelessWidget {
  const _DesktopShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final selected = _selectedIndex(context);
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: selected,
            onDestinationSelected: (i) =>
                context.go(ShellPage._destinations[i].path),
            labelType: NavigationRailLabelType.all,
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
