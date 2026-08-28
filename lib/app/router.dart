import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../ui/pages/accounts/account_detail_page.dart';
import '../ui/pages/accounts/accounts_page.dart';
import '../ui/pages/alerts/alerts_page.dart';
import '../ui/pages/calendar/earnings_calendar_page.dart';
import '../ui/pages/calendar/product_earnings_calendar_page.dart';
import '../ui/pages/holdings/holdings_page.dart';
import '../ui/pages/markets/markets_page.dart';
import '../ui/pages/portfolio/portfolio_page.dart';
import '../ui/pages/settings/settings_page.dart';
import '../ui/shell/shell_page.dart';
import '../ui/pages/stats/stats_page.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/portfolio',
    routes: [
      GoRoute(
        path: '/earnings-calendar',
        builder: (context, state) => const EarningsCalendarPage(),
      ),
      GoRoute(
        path: '/product-earnings',
        builder: (context, state) => const ProductEarningsCalendarPage(),
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
            builder: (context, state) => HoldingsPage(
              initialQuery: state.extra as String?,
            ),
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
