import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/accounts/account_detail_page.dart';
import '../features/accounts/accounts_page.dart';
import '../features/alerts/alerts_page.dart';
import '../features/calendar/earnings_calendar_page.dart';
import '../features/holdings/holdings_page.dart';
import '../features/markets/markets_page.dart';
import '../features/portfolio/portfolio_page.dart';
import '../features/settings/settings_page.dart';
import '../features/shell_page.dart';
import '../features/stats/stats_page.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/portfolio',
    routes: [
      GoRoute(
        path: '/earnings-calendar',
        builder: (context, state) => const EarningsCalendarPage(),
      ),
      ShellRoute(
        builder: (context, state, child) => ShellPage(child: child),
        routes: [
          GoRoute(
            path: '/portfolio',
            builder: (context, state) => const PortfolioPage(),
          ),
          GoRoute(
            path: '/holdings',
            builder: (context, state) => const HoldingsPage(),
          ),
          GoRoute(
            path: '/accounts',
            builder: (context, state) => const AccountsPage(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (context, state) => AccountDetailPage(
                  accountId: int.parse(state.pathParameters['id']!),
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/markets',
            builder: (context, state) => const MarketsPage(),
          ),
          GoRoute(
            path: '/stats',
            builder: (context, state) => const StatsPage(),
          ),
          GoRoute(
            path: '/alerts',
            builder: (context, state) => const AlertsPage(),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsPage(),
          ),
        ],
      ),
    ],
  );
});
