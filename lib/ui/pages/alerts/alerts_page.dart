import 'dart:convert';

import 'package:drift/drift.dart' hide Column, isNull;
import 'package:flutter/material.dart' hide DataRow;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../data/database.dart';
import '../../../domain/target_allocation.dart';
import '../../../services/alert_service.dart';
import '../../components/app_bar_actions.dart';
import '../../components/data_row.dart';
import '../../components/empty_state.dart';
import '../../components/error_state.dart';
import '../../components/form_fields.dart';
import '../../components/section_header.dart';
import '../../components/terminal_card.dart';
import '../../components/terminal_fab.dart';
import '../../tokens.dart';

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
          const TerminalAppBarActions(),
        ],
      ),
      floatingActionButton: TerminalFab(
        onPressed: () => _showAddRuleDialog(context),
        icon: Icons.add,
        label: '添加规则',
      ),
      body: ResponsiveShell(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(alertEventsProvider);
            ref.invalidate(alertRulesProvider);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SectionHeader(label: '最近提醒'),
              events.when(
                data: (list) => list.isEmpty
                    ? const EmptyState(message: '暂无提醒，点击右上角 ⚡ 立即检查')
                    : Column(
                        children: [
                          for (final e in list)
                            DataRow(
                              leading: _colorDot(_eventColor(e.title)),
                              title: e.title,
                              subtitle:
                                  Text('${e.message}\n${Formats.dateTime(e.triggeredAt.toLocal())}'),
                              trailing: const SizedBox.shrink(),
                            ),
                        ],
                      ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ErrorState(
                  message: '提醒数据加载失败，请重试',
                  onRetry: () => ref.invalidate(alertEventsProvider),
                ),
              ),
              const SizedBox(height: T.s4),
              const SectionHeader(label: '提醒规则'),
              rules.when(
                data: (list) => list.isEmpty
                    ? const EmptyState(
                        message: '暂无规则，点击右下角添加\n如：集中度风险、配置比例、跌幅预警、现金流提醒')
                    : Column(
                        children: [
                          for (final r in list)
                            DataRow(
                              leading: _colorDot(_colorFor(AlertRuleType.fromStorage(r.type)),
                                  icon: _iconFor(AlertRuleType.fromStorage(r.type))),
                              title: r.name,
                              subtitle: Text(_paramsSummary(r)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Switch(value: r.enabled, onChanged: (v) => _toggleRule(r, v)),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _confirmDelete(r),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ErrorState(
                  message: '规则加载失败，请重试',
                  onRetry: () => ref.invalidate(alertRulesProvider),
                ),
              ),
              const SizedBox(height: T.s4),
              const _TargetAllocationSection(),
            ],
          ),
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
            style: FilledButton.styleFrom(backgroundColor: T.up),
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
                  decoration: terminalDecoration('规则类型'),
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
              const SizedBox(height: T.s3),
              TerminalTextField(controller: nameCtrl, label: '规则名称'),
              const SizedBox(height: T.s3),
              ValueListenableBuilder<AlertRuleType>(
                valueListenable: type,
                builder: (context, value, _) => Column(
                  children: [
                    TerminalTextField(
                      controller: p1Ctrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      label: switch (value) {
                        AlertRuleType.concentration => '集中度阈值 %（默认 30）',
                        AlertRuleType.assetRatio => '权益类目标占比 %（默认 60）',
                        AlertRuleType.drawdown => '跌幅阈值 %（默认 3）',
                        AlertRuleType.cashflow => '每月日期（1-31）',
                      },
                    ),
                    if (value == AlertRuleType.assetRatio) ...[
                      const SizedBox(height: T.s3),
                      TerminalTextField(
                        controller: p2Ctrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        label: '允许偏离 ±%（默认 15）',
                      ),
                    ],
                    if (value == AlertRuleType.cashflow) ...[
                      const SizedBox(height: T.s3),
                      TerminalTextField(controller: p2Ctrl, label: '事项名称（如 房贷还款）'),
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

Widget _colorDot(Color color, {IconData icon = Icons.notifications_active}) {
  return CircleAvatar(
    radius: 16,
    backgroundColor: color.withValues(alpha: 0.15),
    child: Icon(icon, size: 18, color: color),
  );
}

Color _eventColor(String title) => switch (title) {
      '单日跌幅预警' => T.up,
      '集中度风险' => T.warning,
      '配置比例偏离' => T.accent,
      _ => T.text2,
    };

String _paramsSummary(AlertRuleRow rule) {
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
      AlertRuleType.concentration => T.warning,
      AlertRuleType.assetRatio => T.accent,
      AlertRuleType.drawdown => T.up,
      AlertRuleType.cashflow => T.accent,
    };

/// Editable target-allocation plan. Seeded from the persisted plan on first
/// load; each slider caps at what the other categories leave, so the total
/// can never exceed 100%.
class _TargetAllocationSection extends ConsumerStatefulWidget {
  const _TargetAllocationSection();

  @override
  ConsumerState<_TargetAllocationSection> createState() =>
      _TargetAllocationSectionState();
}

class _TargetAllocationSectionState
    extends ConsumerState<_TargetAllocationSection> {
  Map<AssetCategory, double> _draft = {};
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    // Seed the draft once the persisted plan resolves. Normalizing here
    // keeps a legacy >100% plan from deadlocking the editor (sliders cap
    // at the remainder, so an over-100 draft could never be re-saved).
    Future.microtask(() => ref
        .read(targetAllocationProvider)
        .whenData((value) =>
            setState(() => _draft = normalizeTargetAllocation(value))));
  }

  @override
  Widget build(BuildContext context) {
    final plan = ref.watch(targetAllocationProvider);
    if (!_seeded && plan.hasValue) {
      _seeded = true;
      _draft = normalizeTargetAllocation({...plan.value!});
    }
    final total = _draft.values.fold(0.0, (a, b) => a + b);
    final remaining = (100 - total).clamp(0.0, 100.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(label: '目标配置（计划配比）'),
        Text(
          '设定各大类的目标占比（合计不超过 100%），资产配置卡会对比实际与计划，偏离过大时高亮提示便于再平衡。',
          style: T.label(),
        ),
        const SizedBox(height: T.s3),
        TerminalCard(
          child: Column(
            children: [
              for (final c in AssetCategory.values) _sliderRow(c),
              const SizedBox(height: T.s2),
              Row(
                children: [
                  Text(
                    '合计 ${total.round()}%'
                    '${remaining <= 0 ? ' · 已达上限' : ' · 剩余可分配 ${remaining.round()}%'}',
                    style: T.mono(
                      size: 12,
                      color: total.round() == 100 ? T.text2 : T.warning,
                    ),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () async {
                      // Epsilon guard: binary float sums can land a hair
                      // above 100 for an exact-100 plan.
                      if (total > 100.0001) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('目标配置合计不能超过 100%')),
                        );
                        return;
                      }
                      await saveTargetAllocation(
                        ref.read(daoProvider),
                        _draft,
                      );
                      ref.invalidate(targetAllocationProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已保存目标配置')),
                        );
                      }
                    },
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One category row: its slider is capped at what the other categories
  /// leave over, so the plan total stays <= 100%.
  Widget _sliderRow(AssetCategory c) {
    final others = _draft.entries
        .where((e) => e.key != c)
        .fold(0.0, (a, e) => a + e.value);
    final cap = (100 - others).clamp(0.0, 100.0).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: T.s2),
      child: Row(
        children: [
          Icon(c.icon, size: 18, color: c.color),
          const SizedBox(width: T.s2),
          SizedBox(
            width: 44,
            child: Text(
              c.label,
              style: const TextStyle(fontSize: 13, color: T.text1),
            ),
          ),
          Expanded(
            child: Slider(
              value: (_draft[c] ?? 0).clamp(0.0, cap).toDouble(),
              min: 0,
              max: cap,
              divisions: 20,
              activeColor: c.color,
              onChanged: (v) => setState(() => _draft[c] = v),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              // Show the clamped value so the number matches the slider
              // position even for legacy plans that exceed the cap.
              '${((_draft[c] ?? 0).clamp(0.0, cap)).round()}%',
              style: T.mono(size: 12, color: T.text2),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
