import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../services/history_backfill_service.dart';
import '../tokens.dart';

Future<void> showRebuildHistoryDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('重建历史快照'),
      content: const Text(
        '将联网重新抓取历史收盘价与基金净值，重算全部历史净值快照。\n\n'
        '重建使用已有流水。原流水缺失的本金信息需要另行核对。'
        '需要数秒，期间请保持网络畅通。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('开始重建'),
        ),
      ],
    ),
  );
  if (confirm != true || !context.mounted) return;

  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _RebuildProgressDialog(),
    ),
  );

  BackfillResult result;
  try {
    // Refresh quotes FIRST so the forced rebuild prices today from fresh
    // quotes; the rebuild itself covers today with the same replay cost
    // basis as every earlier day. Overwriting today afterwards with
    // PortfolioCalculator would give it a different cost basis (the
    // replay-vs-current cost gaps on traded holdings), surfacing as a fake
    // daily return.
    await ref.read(marketServiceProvider).refreshAll();
    result = await ref
        .read(historyBackfillServiceProvider)
        .backfill(forceRebuild: true);
    ref.invalidate(cnyRatesProvider);
  } catch (error) {
    result = BackfillResult(
      ok: false,
      days: 0,
      holdings: 0,
      message: '重建失败：$error',
    );
  }
  if (navigator.mounted) navigator.pop();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(result.message ?? (result.ok ? '历史快照已重建' : '重建未完成')),
      backgroundColor: result.ok ? null : T.up,
    ),
  );
}

/// Blocking progress indicator for the manual history rebuild. Not dismissible:
/// a rebuild that is interrupted mid-flight is exactly how days end up frozen
/// on intraday prices.
class _RebuildProgressDialog extends StatelessWidget {
  const _RebuildProgressDialog();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: T.s3),
            Expanded(child: Text('正在重建历史快照…', style: T.label())),
          ],
        ),
      ),
    );
  }
}
