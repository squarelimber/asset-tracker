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
    (
      icon: Icons.donut_large_outlined,
      activeIcon: Icons.donut_large,
      label: '总览',
      path: '/portfolio',
    ),
    (
      icon: Icons.pie_chart_outline,
      activeIcon: Icons.pie_chart,
      label: '持仓',
      path: '/holdings',
    ),
    (
      icon: Icons.account_balance_wallet_outlined,
      activeIcon: Icons.account_balance_wallet,
      label: '账户',
      path: '/accounts',
    ),
    (
      icon: Icons.candlestick_chart_outlined,
      activeIcon: Icons.candlestick_chart,
      label: '行情',
      path: '/markets',
    ),
    (
      icon: Icons.assessment_outlined,
      activeIcon: Icons.assessment,
      label: '统计',
      path: '/stats',
    ),
  ];

  /// Shell-level routes that live inside the [ShellRoute] and are navigated
  /// via [GoRouter.go].  Android back gesture on these pages should navigate
  /// back to the root page (/portfolio) rather than exiting the app. Pushed
  /// routes (/earnings-calendar, /accounts/:id) and the root page itself
  /// keep the normal pop behavior so the app can be exited from 总览.
  static final _shellPaths = {
    for (final d in _destinations) d.path,
    '/transactions',
    '/alerts',
    '/settings',
  };

  @override
  Widget build(BuildContext context) {
    // Exact match (not prefix): a shell-level page has no stack to pop (back
    // gesture -> back to /portfolio), while /accounts/:id and other pushed
    // routes must pop normally. /portfolio itself is allowed to pop so the
    // system back gesture / edge swipe can exit the app from the root page.
    final currentPath = GoRouterState.of(context).uri.path;
    final canPop =
        currentPath == '/portfolio' || !_shellPaths.contains(currentPath);

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
        onDestinationSelected: (i) =>
            context.go(ShellPage._destinations[i].path),
        destinations: [
          for (final d in ShellPage._destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.activeIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }

  int _selectedIndex(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    final i = ShellPage._destinations.indexWhere(
      (d) => path.startsWith(d.path),
    );
    return i < 0 ? 0 : i;
  }
}

/// Persistent desktop navigation, with secondary tools separated from assets.
class _DesktopShell extends StatelessWidget {
  const _DesktopShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: MediaQuery.sizeOf(context).width < 1280 ? 184 : 196,
            decoration: const BoxDecoration(
              color: T.surface,
              border: Border(right: BorderSide(color: T.borderSoft)),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 22, 12, 24),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.stacked_line_chart,
                          color: T.text2,
                          size: 24,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Asset Tracker',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                '资产管理',
                                style: TextStyle(fontSize: 11, color: T.text3),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        _groupLabel('资产管理'),
                        for (final (index, d)
                            in ShellPage._destinations.indexed)
                          _SidebarItem(
                            icon: d.icon,
                            activeIcon: d.activeIcon,
                            label: d.label,
                            selected: path.startsWith(d.path),
                            shortcut: '${index + 1}',
                            onTap: () => context.go(d.path),
                          ),
                        const SizedBox(height: 24),
                        _groupLabel('工具与记录'),
                        _SidebarItem(
                          icon: Icons.receipt_long_outlined,
                          activeIcon: Icons.receipt_long,
                          label: '交易流水',
                          selected: path.startsWith('/transactions'),
                          shortcut: '6',
                          onTap: () => context.go('/transactions'),
                        ),
                        _SidebarItem(
                          icon: Icons.notifications_outlined,
                          activeIcon: Icons.notifications,
                          label: '提醒',
                          selected: path.startsWith('/alerts'),
                          onTap: () => context.go('/alerts'),
                        ),
                        _SidebarItem(
                          icon: Icons.settings_outlined,
                          activeIcon: Icons.settings,
                          label: '设置',
                          selected: path.startsWith('/settings'),
                          onTap: () => context.go('/settings'),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: T.borderSoft),
                      borderRadius: BorderRadius.circular(T.rInput),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.storage_outlined, size: 18, color: T.text3),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '本地数据',
                            style: TextStyle(fontSize: 11, color: T.text2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _groupLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
    child: Text(text, style: T.label(size: 10, color: T.text3)),
  );
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.shortcut,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final color = selected ? T.text1 : T.text2;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Semantics(
        selected: selected,
        child: Material(
          color: selected ? T.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(T.rInput),
          child: InkWell(
            borderRadius: BorderRadius.circular(T.rInput),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    selected ? activeIcon : icon,
                    color: selected ? T.accent : T.text3,
                    size: 18,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (shortcut != null)
                    ExcludeSemantics(
                      child: Text(
                        shortcut!,
                        style: T.mono(size: 10, color: T.text3),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
