import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/earnings_breakdown.dart';
import '../pages/transactions/transactions_page.dart';
import '../tokens.dart';
import 'rebuild_history_dialog.dart';

class EarningsIssueNotice extends ConsumerWidget {
  const EarningsIssueNotice({super.key, required this.issue});

  final EarningsAttributionIssue issue;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('受影响：${issue.date}', style: T.mono(size: 11, color: T.warning)),
      Text(issue.message, style: T.label(color: T.warning)),
      if (issue.canRebuild && kIsWeb) Text('请在手机或桌面端重建后同步。', style: T.label()),
      Wrap(
        spacing: T.s2,
        children: [
          if (issue.canRebuild && !kIsWeb)
            TextButton(
              onPressed: () => showRebuildHistoryDialog(context, ref),
              child: const Text('重建快照'),
            ),
          if (issue.transactionId case final id?)
            TextButton(
              onPressed: () {
                final router = GoRouter.maybeOf(context);
                if (router == null) {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TransactionsPage(
                        initialDate: issue.date,
                        initialTransactionId: id,
                      ),
                    ),
                  );
                } else {
                  router.push<void>('/transactions?date=${issue.date}&id=$id');
                }
              },
              child: const Text('查看关联流水'),
            ),
        ],
      ),
    ],
  );
}
