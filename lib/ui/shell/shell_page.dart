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

  static const _secondaryPaths = {'/transactions', '/alerts', '/settings'};
  static const _analysisPaths = {
    '/earnings-calendar',
    '/product-earnings',
    '/category-earnings',
  };

  static void _openDestination(BuildContext context, String path) {
    final router = GoRouter.of(context);
    if (router.state.uri.path != path) router.push(path);
  }

  @override
  Widget build(BuildContext context) {
    final currentPath = GoRouterState.of(context).uri.path;
    final fallback = switch (currentPath) {
      '/portfolio' => null,
      _ when _analysisPaths.contains(currentPath) => '/stats',
      _ => '/portfolio',
    };
    final router = GoRouter.of(context);
    final matches = router.routerDelegate.currentConfiguration.matches;
    final shellMatch = matches.lastOrNull;
    final hasHistory =
        matches.length > 1 ||
        (shellMatch is ShellRouteMatch && shellMatch.matches.length > 1);
    return PopScope(
      // The inner navigator handles regular history and dialogs. Only direct
      // entry with no previous page needs a fallback on the outer route.
      canPop: fallback == null || hasHistory,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && fallback != null && !router.canPop()) {
          router.go(fallback);
        }
      },
      child: _shellBody(context),
    );
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
          _openDestination(context, _destinations[i].path);
        } else if (i == -2) {
          _openDestination(context, '/transactions');
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
    final path = GoRouterState.of(context).uri.path;
    final hideNavigation =
        ShellPage._secondaryPaths.contains(path) ||
        ShellPage._analysisPaths.contains(path);
    return Scaffold(
      body: child,
      bottomNavigationBar: hideNavigation
          ? null
          : DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: T.borderSoft)),
              ),
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: NavigationBar(
                  selectedIndex: _selectedIndex(context),
                  onDestinationSelected: (i) => ShellPage._openDestination(
                    context,
                    ShellPage._destinations[i].path,
                  ),
                  destinations: [
                    for (final d in ShellPage._destinations)
                      NavigationDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.activeIcon),
                        label: d.label,
                      ),
                  ],
                ),
              ),
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
          if (!ShellPage._analysisPaths.contains(path))
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
                          Image.asset(
                            'assets/branding/logo.png',
                            width: 28,
                            height: 28,
                            semanticLabel: 'Asset Tracker',
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Asset Tracker',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
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
                              onTap: () =>
                                  ShellPage._openDestination(context, d.path),
                            ),
                          const SizedBox(height: 24),
                          _groupLabel('工具与记录'),
                          _SidebarItem(
                            icon: Icons.receipt_long_outlined,
                            activeIcon: Icons.receipt_long,
                            label: '交易流水',
                            selected: path.startsWith('/transactions'),
                            shortcut: '6',
                            onTap: () => ShellPage._openDestination(
                              context,
                              '/transactions',
                            ),
                          ),
                          _SidebarItem(
                            icon: Icons.notifications_outlined,
                            activeIcon: Icons.notifications,
                            label: '提醒',
                            selected: path.startsWith('/alerts'),
                            onTap: () =>
                                ShellPage._openDestination(context, '/alerts'),
                          ),
                          _SidebarItem(
                            icon: Icons.settings_outlined,
                            activeIcon: Icons.settings,
                            label: '设置',
                            selected: path.startsWith('/settings'),
                            onTap: () => ShellPage._openDestination(
                              context,
                              '/settings',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: T.borderSoft),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 12, 12, 12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.storage_outlined,
                            size: 15,
                            color: T.text3,
                          ),
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
            overlayColor: Theme.of(context).textButtonTheme.style?.overlayColor,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                if (selected)
                  const SizedBox(
                    width: 2,
                    height: 16,
                    child: ColoredBox(color: T.accent),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 11,
                  ),
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
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: T.border),
                              borderRadius: BorderRadius.circular(T.rInput),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              child: Text(
                                shortcut!,
                                style: T.mono(size: 10, color: T.text3),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
