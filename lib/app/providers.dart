import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/asset_dao.dart';
import '../data/database.dart';

/// App-wide database instance.
final databaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

/// Data access layer.
final daoProvider = Provider<AssetDao>((ref) => AssetDao(ref.watch(databaseProvider)));

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

final accountsProvider = StreamProvider<List<AccountRow>>(
  (ref) => ref.watch(daoProvider).watchAccounts(),
);

final accountProvider = FutureProvider.family<AccountRow?, int>(
  (ref, id) => ref.watch(daoProvider).getAccount(id),
);

// ---------------------------------------------------------------------------
// Holdings
// ---------------------------------------------------------------------------

final holdingsProvider = StreamProvider<List<HoldingRow>>(
  (ref) => ref.watch(daoProvider).watchHoldings(),
);

final holdingsByAccountProvider = StreamProvider.family<List<HoldingRow>, int>(
  (ref, accountId) => ref.watch(daoProvider).watchHoldingsByAccount(accountId),
);

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

final transactionsProvider = StreamProvider<List<TransactionRow>>(
  (ref) => ref.watch(daoProvider).watchTransactions(),
);

final transactionsByAccountProvider = StreamProvider.family<List<TransactionRow>, int>(
  (ref, accountId) => ref.watch(daoProvider).watchTransactionsByAccount(accountId),
);

final transactionsByHoldingProvider = StreamProvider.family<List<TransactionRow>, int>(
  (ref, holdingId) => ref.watch(daoProvider).watchTransactionsByHolding(holdingId),
);

// ---------------------------------------------------------------------------
// Snapshots
// ---------------------------------------------------------------------------

final snapshotsProvider = StreamProvider<List<SnapshotRow>>(
  (ref) => ref.watch(daoProvider).watchSnapshots(),
);

// ---------------------------------------------------------------------------
// Alert rules
// ---------------------------------------------------------------------------

final alertRulesProvider = StreamProvider<List<AlertRuleRow>>(
  (ref) => ref.watch(daoProvider).watchAlertRules(),
);

final alertEventsProvider = StreamProvider<List<AlertEventRow>>(
  (ref) => ref.watch(daoProvider).watchRecentAlertEvents(),
);
