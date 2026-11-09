import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../domain/portfolio_calculator.dart';
import '../../../domain/target_allocation.dart';
import '../../tokens.dart';

/// Edit the same allocation plan displayed in the overview card.
class TargetAllocationDialog extends ConsumerStatefulWidget {
  const TargetAllocationDialog({super.key, required this.summary});

  final PortfolioSummary summary;

  @override
  ConsumerState<TargetAllocationDialog> createState() =>
      _TargetAllocationDialogState();
}

class _TargetAllocationDialogState
    extends ConsumerState<TargetAllocationDialog> {
  final _controllers = <AssetCategory, TextEditingController>{};
  final _original = <AssetCategory, double>{};
  final _initialText = <AssetCategory, String>{};
  bool _loading = true;
  bool _saving = false;
  bool _defaultPlan = false;
  String? _loadedRaw;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await ref.read(daoProvider).getSetting(targetAllocationKey);
      final plan = parseTargetAllocation(raw);
      if (!mounted) return;
      for (final category in AssetCategory.values) {
        _original[category] = plan[category] ?? 0;
        _initialText[category] = _format(plan[category] ?? 0);
        _controllers[category] = TextEditingController(
          text: _initialText[category],
        );
      }
      setState(() {
        _loadedRaw = raw;
        _defaultPlan = raw == null || raw.isEmpty;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '无法读取目标配置，请关闭后重试';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _format(double value) => value.toStringAsFixed(2);

  double? _value(AssetCategory category) {
    final input = _controllers[category]!.text.trim();
    if (!RegExp(r'^(?:\d{1,3}(?:\.\d{0,8})?|\.\d{1,8})$').hasMatch(input)) {
      return null;
    }
    final value = double.tryParse(input);
    if (value == null || !value.isFinite || value < 0 || value > 100) {
      return null;
    }
    return input == _initialText[category] ? _original[category] : value;
  }

  @override
  Widget build(BuildContext context) {
    final values = <AssetCategory, double?>{
      if (!_loading && _controllers.isNotEmpty)
        for (final category in AssetCategory.values) category: _value(category),
    };
    final valid =
        values.length == AssetCategory.values.length &&
        values.values.every((value) => value != null);
    final dirty =
        values.isNotEmpty &&
        values.entries.any(
          (entry) =>
              entry.value == null ||
              (entry.value! - _original[entry.key]!).abs() > 1e-9,
        );
    final total = values.values.fold<double>(
      0,
      (sum, value) => sum + (value ?? 0),
    );
    final canSave = valid && total <= 100.000000001 && !_saving;

    return AlertDialog(
      title: const Text('调整目标配置'),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _controllers.isEmpty
            ? Text(_error ?? '加载失败')
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_defaultPlan)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('当前为默认参考配置，请按自己的计划调整。'),
                      ),
                    const Text(
                      '实际占比按总资产计算，不包含负债。可输入数值或拖动滑块；未分配部分不指定目标。目标仅保存在本机，可通过备份转移，不随设备同步。',
                    ),
                    const SizedBox(height: 12),
                    for (final category in AssetCategory.values)
                      _categoryRow(category, values[category]),
                    const SizedBox(height: 8),
                    Text(
                      !valid
                          ? '请输入 0–100 之间的数字，最多八位小数'
                          : total > 100.000000001
                          ? '合计 ${_format(total)}% · 目标总和不能超过 100%'
                          : '合计 ${_format(total)}% · 剩余可分配 ${_format((100 - total).clamp(0.0, 100.0))}%',
                      style: T.label(color: canSave ? T.text2 : T.warning),
                    ),
                    if (dirty) Text('修改尚未保存', style: T.label(color: T.warning)),
                    if (_error != null)
                      Text(_error!, style: T.label(color: T.warning)),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: !canSave
              ? null
              : () async {
                  setState(() {
                    _saving = true;
                    _error = null;
                  });
                  try {
                    final dao = ref.read(daoProvider);
                    await dao.transaction(() async {
                      // A restore or another local edit must not be silently
                      // overwritten by a dialog that was already open.
                      final current = await dao.getSetting(targetAllocationKey);
                      if (current != _loadedRaw) throw const _PlanChanged();
                      await saveExactTargetAllocation(dao, {
                        for (final entry in values.entries)
                          entry.key: entry.value!,
                      });
                    });
                    ref.invalidate(targetAllocationProvider);
                    if (context.mounted) Navigator.pop(context);
                  } on _PlanChanged {
                    if (mounted) {
                      setState(() {
                        _saving = false;
                        _error = '目标配置已被其他操作更改，请关闭后重新打开';
                      });
                    }
                  } catch (_) {
                    if (mounted) {
                      setState(() {
                        _saving = false;
                        _error = '保存失败，请重试';
                      });
                    }
                  }
                },
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }

  Widget _categoryRow(AssetCategory category, double? target) {
    final total = widget.summary.totalAssets;
    final matches = widget.summary.categoryBreakdown.where(
      (item) => item.category == category,
    );
    final amount = matches.isEmpty ? 0.0 : matches.first.marketValue;
    final actual = total > 0 ? amount / total * 100 : null;
    final deviation = actual != null && target != null ? actual - target : null;
    final signed = deviation == null
        ? '--'
        : '${deviation >= 0 ? '+' : ''}${_format(deviation)} 个百分点';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            category.label,
            style: TextStyle(
              color: category.color,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '当前 ${actual == null ? '--' : '${_format(actual)}%'} · 偏离 $signed',
            style: T.label(),
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: (target ?? 0).clamp(0.0, 100.0),
                  min: 0,
                  max: 100,
                  activeColor: category.color,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() {
                          _controllers[category]!.text = _format(value);
                        }),
                ),
              ),
              SizedBox(
                width: 80,
                child: TextField(
                  key: ValueKey('target-${category.storageName}'),
                  controller: _controllers[category],
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '${category.label}目标',
                    suffixText: '%',
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlanChanged implements Exception {
  const _PlanChanged();
}
