import 'dart:convert';

import 'package:drift/drift.dart' hide Column, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../data/database.dart';
import '../../services/alert_service.dart';

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

  Future<void> _runNow() async {
    if (_running) return;
    setState(() => _running = true);
    final events = await ref.read(alertServiceProvider).evaluateAll();
    setState(() => _running = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(events.isEmpty ? '检查完成，无新提醒' : '触发 ${events.length} 条新提醒')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(alertRulesProvider);
    final events = ref.watch(alertEventsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('提醒'),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddRuleDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('添加规则'),
      ),
      body: ResponsiveShell(
        child: ListView(
          children: [
            Text('最近提醒', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            events.when(
              data: (list) => list.isEmpty
                  ? const _Hint('暂无提醒，点击右上角 ⚡ 立即检查')
                  : Column(
                      children: [
                        for (final e in list) ...[
                          _EventTile(event: e),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('加载失败: $e'),
            ),
            const SizedBox(height: 24),
            Text('提醒规则', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            rules.when(
              data: (list) => list.isEmpty
                  ? const _Hint('暂无规则，点击右下角添加\n如：集中度风险、配置比例、跌幅预警、现金流提醒')
                  : Column(
                      children: [
                        for (final r in list) ...[
                          _RuleTile(
                            rule: r,
                            onDelete: () => _confirmDelete(r),
                            onToggle: (v) => _toggleRule(r, v),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('加载失败: $e'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleRule(AlertRuleRow rule, bool enabled) async {
    await ref.read(daoProvider).updateAlertRule(
          rule.copyWith(enabled: enabled),
        );
  }

  Future<void> _confirmDelete(AlertRuleRow rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除规则「${rule.name}」吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.up),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(daoProvider).deleteAlertRule(rule.id);
    }
  }

  Future<void> _showAddRuleDialog(BuildContext context) async {
    final type = ValueNotifier<AlertRuleType>(AlertRuleType.concentration);
    final nameCtrl = TextEditingController();
    final p1Ctrl = TextEditingController();
    final p2Ctrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加提醒规则'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<AlertRuleType>(
                valueListenable: type,
                builder: (context, value, _) => DropdownButtonFormField<AlertRuleType>(
                  initialValue: value,
                  decoration: const InputDecoration(labelText: '规则类型'),
                  items: [
                    for (final t in AlertRuleType.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: (v) {
                    type.value = v ?? AlertRuleType.concentration;
                    p1Ctrl.clear();
                    p2Ctrl.clear();
                  },
                ),
              ),
              const SizedBox(height: 12),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '规则名称')),
              const SizedBox(height: 12),
              ValueListenableBuilder<AlertRuleType>(
                valueListenable: type,
                builder: (context, value, _) => Column(
                  children: [
                    TextField(
                      controller: p1Ctrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: switch (value) {
                        AlertRuleType.concentration => '集中度阈值 %（默认 30）',
                        AlertRuleType.assetRatio => '权益类目标占比 %（默认 60）',
                        AlertRuleType.drawdown => '跌幅阈值 %（默认 3）',
                        AlertRuleType.cashflow => '每月日期（1-31）',
                      }),
                    ),
                    if (value == AlertRuleType.assetRatio) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: p2Ctrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: '允许偏离 ±%（默认 15）'),
                      ),
                    ],
                    if (value == AlertRuleType.cashflow) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: p2Ctrl,
                        decoration: const InputDecoration(labelText: '事项名称（如 房贷还款）'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final selected = type.value;
              final name = nameCtrl.text.trim().isEmpty ? selected.label : nameCtrl.text.trim();
              final params = <String, dynamic>{};
              switch (selected) {
                case AlertRuleType.concentration:
                  params['threshold'] = (double.tryParse(p1Ctrl.text.trim()) ?? 30) / 100;
                case AlertRuleType.assetRatio:
                  params['target'] = (double.tryParse(p1Ctrl.text.trim()) ?? 60) / 100;
                  params['tolerance'] = (double.tryParse(p2Ctrl.text.trim()) ?? 15) / 100;
                case AlertRuleType.drawdown:
                  params['threshold'] = (double.tryParse(p1Ctrl.text.trim()) ?? 3) / 100;
                case AlertRuleType.cashflow:
                  params['dayOfMonth'] = (int.tryParse(p1Ctrl.text.trim()) ?? 1).clamp(1, 31);
                  params['label'] = p2Ctrl.text.trim().isEmpty ? name : p2Ctrl.text.trim();
              }
              await ref.read(daoProvider).createAlertRule(AlertRulesCompanion.insert(
                type: selected.storageName,
                name: name,
                params: Value(jsonEncode(params)),
              ));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    p1Ctrl.dispose();
    p2Ctrl.dispose();
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final AlertEventRow event;

  @override
  Widget build(BuildContext context) {
    final color = switch (event.title) {
      '单日跌幅预警' => AppColors.up,
      '集中度风险' => AppColors.warning,
      '配置比例偏离' => AppColors.primary,
      _ => Colors.teal,
    };
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(Icons.notifications_active, size: 18, color: color),
        ),
        title: Text(event.title),
        subtitle: Text('${event.message}\n${Formats.dateTime(event.triggeredAt.toLocal())}'),
        isThreeLine: true,
      ),
    );
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({required this.rule, required this.onDelete, required this.onToggle});

  final AlertRuleRow rule;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final type = AlertRuleType.fromStorage(rule.type);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: _colorFor(type).withValues(alpha: 0.15),
          child: Icon(_iconFor(type), size: 18, color: _colorFor(type)),
        ),
        title: Text(rule.name),
        subtitle: Text(_paramsSummary(rule)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: rule.enabled, onChanged: onToggle),
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: onDelete),
          ],
        ),
      ),
    );
  }

  static String _paramsSummary(AlertRuleRow rule) {
    final params = _decodeParams(rule.params);
    return switch (AlertRuleType.fromStorage(rule.type)) {
      AlertRuleType.concentration =>
        '单笔持仓占比 > ${((params['threshold'] as num?)?.toDouble() ?? 0.3) * 100}% 时提醒',
      AlertRuleType.assetRatio =>
        '权益类目标 ${((params['target'] as num?)?.toDouble() ?? 0.6) * 100}% ± ${((params['tolerance'] as num?)?.toDouble() ?? 0.15) * 100}%',
      AlertRuleType.drawdown =>
        '单日跌幅 > ${((params['threshold'] as num?)?.toDouble() ?? 0.03) * 100}% 时提醒',
      AlertRuleType.cashflow => '每月 ${params['dayOfMonth'] ?? 1} 号：${params['label'] ?? rule.name}',
    };
  }
}

Map<String, dynamic> _decodeParams(String json) {
  try {
    final decoded = jsonDecode(json);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

IconData _iconFor(AlertRuleType type) => switch (type) {
      AlertRuleType.concentration => Icons.warning_amber_rounded,
      AlertRuleType.assetRatio => Icons.scale,
      AlertRuleType.drawdown => Icons.trending_down,
      AlertRuleType.cashflow => Icons.event_repeat,
    };

Color _colorFor(AlertRuleType type) => switch (type) {
      AlertRuleType.concentration => AppColors.warning,
      AlertRuleType.assetRatio => AppColors.primary,
      AlertRuleType.drawdown => AppColors.up,
      AlertRuleType.cashflow => Colors.teal,
    };
