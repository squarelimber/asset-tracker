import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide DataRow;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../data/database.dart';
import '../../../services/alert_notification_service.dart';
import '../../../services/alert_service.dart';
import '../../components/data_row.dart';
import '../../components/empty_state.dart';
import '../../components/error_state.dart';
import '../../components/secondary_page_back_button.dart';
import '../../components/terminal_fab.dart';
import '../../tokens.dart';
import '../holdings/holding_detail_sheet.dart';
import '../portfolio/portfolio_page.dart' show summaryProvider;
import '../portfolio/target_allocation_dialog.dart';
import 'alert_rule_editor.dart';

final alertServiceProvider = Provider<AlertService>(
  (ref) => AlertService(ref.watch(daoProvider)),
);

class AlertsPage extends ConsumerStatefulWidget {
  const AlertsPage({super.key});
  @override
  ConsumerState<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends ConsumerState<AlertsPage> {
  bool _running = false;
  bool _showRules = false;
  String? _lastChecked;
  String? _notificationsEnabled;
  bool _statusLoaded = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadStatus);
  }

  Future<void> _loadStatus() async {
    if (!mounted) return;
    final dao = ref.read(daoProvider);
    final last = await dao.getSetting(AlertService.lastCheckedKey);
    final enabled = await dao.getSetting(AlertNotificationService.enabledKey);
    if (!mounted) return;
    setState(() {
      _lastChecked = last;
      _notificationsEnabled = enabled;
      _statusLoaded = true;
    });
  }

  Future<void> _runNow() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      final events = await ref
          .read(alertNotificationServiceProvider)
          .runCheck();
      await _loadStatus();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            events.isEmpty ? '检查完成，无新提醒' : '检查完成，新增 ${events.length} 条提醒',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('检查失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _openEvent(AlertEventRow event) async {
    if (event.title == '集中度风险') {
      final id = int.tryParse(
        RegExp(r'持仓 #(\d+)').firstMatch(event.message)?.group(1) ?? '',
      );
      if (id == null) return;
      final holding = await ref.read(daoProvider).getHolding(id);
      if (!mounted) return;
      if (holding == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该持仓已不存在')));
      } else {
        showHoldingDetailSheet(context, ref, holding);
      }
    } else if (event.title == '配置比例偏离') {
      try {
        final summary = await ref.read(summaryProvider.future);
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (_) => TargetAllocationDialog(summary: summary),
          );
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('资产配置加载失败')));
        }
      }
    }
  }

  Future<void> _confirmDelete(AlertRuleRow rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除规则「${rule.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(daoProvider).deleteAlertRule(rule.id);
    }
  }

  String get _notificationStatus {
    if (!_statusLoaded) return '通知状态读取中';
    if (kIsWeb) return '网页版仅显示站内提醒，不发送系统通知';
    if (_notificationsEnabled == 'false') return '系统通知已在应用中关闭';
    return ref.read(notificationServiceProvider).canShow
        ? '系统通知可用'
        : '系统通知不可用，请检查系统权限';
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(alertRulesProvider);
    final events = ref.watch(alertEventsProvider);
    final checked = DateTime.tryParse(_lastChecked ?? '')?.toLocal();
    return Scaffold(
      appBar: AppBar(
        title: const Text('提醒'),
        leading: Responsive.isDesktop(context)
            ? null
            : const SecondaryPageBackButton(),
        actions: [
          IconButton(
            tooltip: '立即检查',
            onPressed: _running ? null : _runNow,
            icon: _running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bolt),
          ),
        ],
      ),
      floatingActionButton: _showRules
          ? TerminalFab(
              onPressed: () => showAlertRuleEditor(context),
              icon: Icons.add,
              label: '添加规则',
            )
          : null,
      body: ResponsiveShell(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(alertEventsProvider);
            ref.invalidate(alertRulesProvider);
            await _loadStatus();
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Text(
                checked == null
                    ? '上次检查：暂无记录'
                    : '上次检查：${Formats.dateTime(checked)}',
                style: T.label(),
              ),
              const SizedBox(height: 4),
              Text(_notificationStatus, style: T.label()),
              const SizedBox(height: 4),
              Text(
                '开启应用通知时，启动或刷新行情会检查；也可手动检查。关闭 App 后不会定时检查，通知发送失败不会自动补发。',
                style: T.label(),
              ),
              if (!kIsWeb)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () async {
                      await context.push('/settings');
                      if (mounted) await _loadStatus();
                    },
                    child: const Text('通知设置'),
                  ),
                ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('提醒记录')),
                  ButtonSegment(value: true, label: Text('规则设置')),
                ],
                selected: {_showRules},
                onSelectionChanged: (selected) =>
                    setState(() => _showRules = selected.first),
              ),
              const SizedBox(height: 16),
              if (!_showRules)
                events.when(
                  data: (list) => list.isEmpty
                      ? const EmptyState(message: '暂无提醒，点击右上角“立即检查”')
                      : Column(
                          children: [
                            for (final e in list)
                              DataRow(
                                leading: const Icon(
                                  Icons.notifications_outlined,
                                  color: T.text2,
                                ),
                                title: e.title,
                                subtitle: Text(
                                  '${e.message}\n${Formats.dateTime(e.triggeredAt.toLocal())}',
                                ),
                                trailing: const SizedBox.shrink(),
                                onTap:
                                    (e.title == '配置比例偏离' ||
                                        (e.title == '集中度风险' &&
                                            RegExp(
                                              r'持仓 #\d+',
                                            ).hasMatch(e.message)))
                                    ? () => _openEvent(e)
                                    : null,
                                showChevron:
                                    e.title == '配置比例偏离' ||
                                    (e.title == '集中度风险' &&
                                        RegExp(r'持仓 #\d+').hasMatch(e.message)),
                              ),
                          ],
                        ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => ErrorState(
                    message: '提醒数据加载失败，请重试',
                    onRetry: () => ref.invalidate(alertEventsProvider),
                  ),
                )
              else
                rules.when(
                  data: (list) => list.isEmpty
                      ? const EmptyState(message: '暂无规则，点击下方“添加规则”')
                      : Column(
                          children: [
                            for (final rule in list)
                              DataRow(
                                leading: const Icon(Icons.tune, color: T.text2),
                                title: rule.name,
                                subtitle: Text(_paramsSummary(rule)),
                                onTap: () =>
                                    showAlertRuleEditor(context, rule: rule),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Switch(
                                      value: rule.enabled,
                                      onChanged: (enabled) => ref
                                          .read(daoProvider)
                                          .updateAlertRule(
                                            rule.copyWith(enabled: enabled),
                                          ),
                                    ),
                                    IconButton(
                                      tooltip: '删除规则',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => _confirmDelete(rule),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 80),
                          ],
                        ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => ErrorState(
                    message: '规则加载失败，请重试',
                    onRetry: () => ref.invalidate(alertRulesProvider),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _paramsSummary(AlertRuleRow rule) {
  final p = decodeRuleParams(rule.params);
  String pct(String key, double fallback) =>
      '${(((p[key] as num?)?.toDouble() ?? fallback) * 100).toStringAsFixed(1)}%';
  return switch (AlertRuleType.fromStorage(rule.type)) {
    AlertRuleType.concentration => '单项持仓占比超过 ${pct('threshold', .3)} 时提醒',
    AlertRuleType.assetRatio =>
      p['followTarget'] == true
          ? '权益类跟随本机配置目标 · 允许偏离 ${(p['tolerance'] as num? ?? .15) * 100} 个百分点'
          : '权益类自定义目标 ${pct('target', .6)} · 允许偏离 ${(p['tolerance'] as num? ?? .15) * 100} 个百分点',
    AlertRuleType.drawdown => '组合单日跌幅超过 ${pct('threshold', .03)} 时提醒',
    AlertRuleType.cashflow =>
      '每月 ${p['dayOfMonth'] ?? 1} 日：${p['label'] ?? rule.name}${(p['advanceDays'] as num? ?? 0) > 0 ? ' · 提前 ${p['advanceDays']} 天' : ''}${p['shortMonthLastDay'] == true ? ' · 短月按月末' : ''}',
  };
}
