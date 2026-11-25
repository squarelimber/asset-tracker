import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/category_earnings.dart';
import 'providers.dart';

typedef CategoryEarningsPeriod = ({String from, String to});

/// Shares recorded historical values with the calendar. Current holdings are
/// used only to resolve the allocation category, never to reprice history.
final categoryEarningsProvider = FutureProvider.autoDispose
    .family<CategoryEarningsReport, CategoryEarningsPeriod>((
      ref,
      period,
    ) async {
      final snapshots = ref.watch(snapshotsProvider.future);
      final holdings = ref.watch(holdingsProvider.future);
      final transactions = ref.watch(transactionsProvider.future);
      return categoryEarningsOf(
        await snapshots,
        holdings: await holdings,
        transactions: await transactions,
        from: period.from,
        to: period.to,
      );
    });
