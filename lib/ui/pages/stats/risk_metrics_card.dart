import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/history_sync.dart';
import '../../../data/database.dart';
import '../../../domain/risk_history_status.dart';
import '../../../domain/risk_metrics.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

const riskFreeRateSettingKey = 'risk_free_rate_annual';
const defaultRiskFreeRate = 0.01;

/// The persisted value is a fraction: 0.01 represents 1% per year.
final riskFreeRateProvider = StreamProvider<double>((ref) {
  return ref.watch(daoProvider).watchSetting(riskFreeRateSettingKey).map((raw) {
    final value = double.tryParse(raw ?? '');
    return value != null && value.isFinite && value >= -0.05 && value <= 1
        ? value
        : defaultRiskFreeRate;
  });
});

class RiskMetricsCard extends ConsumerWidget {
  const RiskMetricsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshots = ref.watch(snapshotsProvider);
    final transactions = ref.watch(transactionsProvider);
    final rate = ref.watch(riskFreeRateProvider);
    final dirty = ref.watch(historyDirtyFlagProvider);
    final fullRebuild = ref.watch(historyFullRebuildFlagProvider);
    final historyPending =
        dirty.valueOrNull == historyDirtySet || fullRebuild.valueOrNull == '1';
    final hidden = ref.watch(hideAmountsProvider);
    AsyncValue<List<HoldingRow>>? pendingHoldings;
    AsyncValue<List<SyncTombstoneRow>>? pendingTombstones;
    var coveredBySyncedHistory = false;
    if (historyPending) {
      final currentHoldings = ref.watch(holdingsProvider);
      final currentTombstones = ref.watch(riskHistoryTombstonesProvider);
      pendingHoldings = currentHoldings;
      pendingTombstones = currentTombstones;
      if (!snapshots.isLoading &&
          !snapshots.hasError &&
          snapshots.hasValue &&
          !transactions.isLoading &&
          !transactions.hasError &&
          transactions.hasValue &&
          !currentHoldings.isLoading &&
          !currentHoldings.hasError &&
          currentHoldings.hasValue &&
          !currentTombstones.isLoading &&
          !currentTombstones.hasError &&
          currentTombstones.hasValue) {
        coveredBySyncedHistory = riskHistoryCoversLedger(
          snapshots.valueOrNull!,
          currentHoldings.valueOrNull!,
          transactions.valueOrNull!,
          currentTombstones.valueOrNull!,
        );
      }
    }
    final historyBlocked = historyPending && !coveredBySyncedHistory;
    final loading =
        snapshots.isLoading ||
        transactions.isLoading ||
        rate.isLoading ||
        dirty.isLoading ||
        fullRebuild.isLoading ||
        (pendingHoldings?.isLoading ?? false) ||
        (pendingTombstones?.isLoading ?? false);
    final failed =
        snapshots.hasError ||
        transactions.hasError ||
        rate.hasError ||
        dirty.hasError ||
        fullRebuild.hasError ||
        (pendingHoldings?.hasError ?? false) ||
        (pendingTombstones?.hasError ?? false);
    RiskMetricsEstimate? estimate;
    if (!loading &&
        !failed &&
        !historyBlocked &&
        snapshots.hasValue &&
        transactions.hasValue &&
        rate.hasValue &&
        dirty.hasValue &&
        fullRebuild.hasValue) {
      estimate = estimateRiskMetrics(
        snapshots.valueOrNull!,
        transactions.valueOrNull!,
        annualRiskFreeRate: rate.valueOrNull!,
      );
    }
    final reason = failed
        ? '风险数据加载失败，请重试'
        : loading
        ? '正在计算风险指标…'
        : historyBlocked
        ? '流水已更新，历史快照待重建后计算'
        : estimate?.unavailableReason;
    final sample = estimate;
    final period = sample == null
        ? null
        : sample.startDate == null || sample.endDate == null
        ? '有效样本 ${sample.sampleCount} 天'
        : '${sample.startDate} 至 ${sample.endDate} · 有效样本 ${sample.sampleCount} 天';
    return TerminalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('估算夏普比率', style: T.label(size: 12))),
              TextButton.icon(
                onPressed: rate.hasValue
                    ? () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            _RiskFreeRateDialog(current: rate.valueOrNull!),
                      )
                    : null,
                icon: const Icon(Icons.tune, size: 16),
                label: Text(
                  '无风险利率 ${Formats.pct(rate.valueOrNull ?? defaultRiskFreeRate)}',
                ),
              ),
            ],
          ),
          const SizedBox(height: T.s1),
          Wrap(
            spacing: T.s5,
            runSpacing: T.s3,
            children: [
              _Metric(
                label: '夏普比率',
                value: hidden
                    ? '****'
                    : estimate?.sharpe?.toStringAsFixed(2) ?? '--',
              ),
              _Metric(
                label: '年化波动率',
                value: hidden
                    ? '****'
                    : estimate?.annualizedVolatility == null
                    ? '--'
                    : Formats.pct(estimate!.annualizedVolatility!),
              ),
            ],
          ),
          const SizedBox(height: T.s3),
          if (period != null) Text(period, style: T.label()),
          if (sample?.interruptionReason case final reason?)
            Text(
              sample!.interruptedDate == null
                  ? reason
                  : '最近中断 ${sample.interruptedDate} · $reason',
              style: T.label(color: T.text3),
            ),
          if (reason != null) ...[
            const SizedBox(height: T.s2),
            Text(reason, style: T.label(color: T.warning)),
          ],
          if (failed)
            TextButton(
              onPressed: () {
                ref.invalidate(snapshotsProvider);
                ref.invalidate(transactionsProvider);
                ref.invalidate(riskFreeRateProvider);
                ref.invalidate(historyDirtyFlagProvider);
                ref.invalidate(historyFullRebuildFlagProvider);
                if (historyPending) {
                  ref.invalidate(holdingsProvider);
                  ref.invalidate(riskHistoryTombstonesProvider);
                }
              },
              child: const Text('重试'),
            ),
          const SizedBox(height: T.s2),
          Text(
            '使用最近可用的连续区间，最多 365 个自然日，按 365 天年化。可核对的交易日参与计算；本金进出按期末发生估算，缺少快照、流水待重建或本金变化无法核对时中断。手动平滑和历史汇率近似可能影响结果。',
            style: T.label(),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: T.label()),
      const SizedBox(height: T.s1),
      Text(value, style: T.mono(size: 20, weight: FontWeight.w600)),
    ],
  );
}

class _RiskFreeRateDialog extends ConsumerStatefulWidget {
  const _RiskFreeRateDialog({required this.current});
  final double current;

  @override
  ConsumerState<_RiskFreeRateDialog> createState() =>
      _RiskFreeRateDialogState();
}

class _RiskFreeRateDialogState extends ConsumerState<_RiskFreeRateDialog> {
  late final TextEditingController _controller;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: Formats.plainNum(widget.current * 100, decimals: 4),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final percent = double.tryParse(_controller.text.trim());
    if (percent == null || !percent.isFinite || percent < -5 || percent > 100) {
      setState(() => _error = '请输入 -5 到 100 之间的年利率');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(daoProvider)
          .setSetting(riskFreeRateSettingKey, '${percent / 100}');
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('设置无风险年利率'),
    content: TextField(
      controller: _controller,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      decoration: InputDecoration(
        labelText: '年利率（%）',
        suffixText: '%',
        errorText: _error,
      ),
      autofocus: true,
      onSubmitted: (_) {
        if (!_saving) _save();
      },
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _saving ? null : _save, child: const Text('保存')),
    ],
  );
}
