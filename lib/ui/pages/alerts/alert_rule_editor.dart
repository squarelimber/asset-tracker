import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../core/symbols.dart';
import '../../../data/database.dart';
import '../../../domain/target_allocation.dart';
import '../../tokens.dart';
import '../portfolio/portfolio_page.dart' show summaryProvider;

Future<void> showAlertRuleEditor(BuildContext context, {AlertRuleRow? rule}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _RuleEditor(rule: rule),
    );

Map<String, dynamic> decodeRuleParams(String raw) {
  try {
    final value = jsonDecode(raw);
    return value is Map<String, dynamic> ? value : {};
  } catch (_) {
    return {};
  }
}

class _RuleEditor extends ConsumerStatefulWidget {
  const _RuleEditor({this.rule});
  final AlertRuleRow? rule;

  @override
  ConsumerState<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends ConsumerState<_RuleEditor> {
  final _form = GlobalKey<FormState>();
  late AlertRuleType _type;
  late bool _followTarget;
  late bool _shortMonth;
  late final TextEditingController _name;
  late final TextEditingController _primary;
  late final TextEditingController _secondary;
  late final TextEditingController _advance;
  late final Map<String, dynamic> _original;
  late final String _initialPrimary;
  late final String _initialSecondary;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _type = rule == null
        ? AlertRuleType.concentration
        : AlertRuleType.fromStorage(rule.type);
    _original = decodeRuleParams(rule?.params ?? '{}');
    _followTarget = rule == null || _original['followTarget'] == true;
    _shortMonth = _original['shortMonthLastDay'] == true;
    _name = TextEditingController(text: rule?.name ?? '');
    _primary = TextEditingController();
    _secondary = TextEditingController();
    _advance = TextEditingController(text: '${_original['advanceDays'] ?? 0}');
    _setFields();
    _initialPrimary = _primary.text;
    _initialSecondary = _secondary.text;
  }

  void _setFields() {
    final p = _original;
    String percent(String key, double fallback) =>
        (((p[key] as num?)?.toDouble() ?? fallback) * 100)
            .toStringAsFixed(8)
            .replaceFirst(RegExp(r'\.?0+$'), '');
    switch (_type) {
      case AlertRuleType.concentration:
        _primary.text = percent('threshold', .3);
        _secondary.clear();
      case AlertRuleType.assetRatio:
        _primary.text = percent('target', .6);
        _secondary.text = percent('tolerance', .15);
      case AlertRuleType.drawdown:
        _primary.text = percent('threshold', .03);
        _secondary.clear();
      case AlertRuleType.cashflow:
        _primary.text = '${p['dayOfMonth'] ?? 1}';
        _secondary.text = '${p['label'] ?? ''}';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _primary.dispose();
    _secondary.dispose();
    _advance.dispose();
    super.dispose();
  }

  String? _number(
    String? text, {
    required double min,
    required double max,
    bool integer = false,
  }) {
    final n = double.tryParse(text?.trim() ?? '');
    if (n == null ||
        !n.isFinite ||
        n < min ||
        n > max ||
        (integer && n != n.roundToDouble())) {
      return '请输入 $min–$max${integer ? ' 的整数' : ' 的数字'}';
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final rule = widget.rule;
    final params = <String, dynamic>{..._original};
    final name = _name.text.trim().isEmpty ? _type.label : _name.text.trim();
    double percentValue(
      TextEditingController controller,
      String initial,
      String key,
    ) {
      final original = _original[key];
      if (widget.rule != null &&
          controller.text == initial &&
          original is num) {
        return original.toDouble();
      }
      return double.parse(controller.text.trim()) / 100;
    }

    switch (_type) {
      case AlertRuleType.concentration:
      case AlertRuleType.drawdown:
        params['threshold'] = percentValue(
          _primary,
          _initialPrimary,
          'threshold',
        );
      case AlertRuleType.assetRatio:
        params['followTarget'] = _followTarget;
        if (!_followTarget) {
          params['target'] = percentValue(_primary, _initialPrimary, 'target');
        }
        params['tolerance'] = percentValue(
          _secondary,
          _initialSecondary,
          'tolerance',
        );
      case AlertRuleType.cashflow:
        params['dayOfMonth'] = double.parse(_primary.text.trim()).toInt();
        params['label'] = _secondary.text.trim().isEmpty
            ? name
            : _secondary.text.trim();
        params['advanceDays'] = double.parse(_advance.text.trim()).toInt();
        params['shortMonthLastDay'] = _shortMonth;
    }
    try {
      final dao = ref.read(daoProvider);
      if (rule == null) {
        await dao.createAlertRule(
          AlertRulesCompanion.insert(
            type: _type.storageName,
            name: name,
            params: Value(jsonEncode(params)),
          ),
        );
      } else {
        await dao.updateAlertRule(
          rule.copyWith(name: name, params: jsonEncode(params)),
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(summaryProvider).valueOrNull;
    final plan = ref.watch(targetAllocationProvider).valueOrNull;
    final holdings = ref.watch(holdingsProvider).valueOrNull;
    final rates = ref.watch(cnyRatesProvider).valueOrNull;
    final equity = summary?.categoryBreakdown
        .where((e) => e.category == AssetCategory.equity)
        .fold<double>(0, (sum, e) => sum + e.marketValue);
    final equityPct = summary != null && summary.totalAssets > 0
        ? (equity ?? 0) / summary.totalAssets * 100
        : null;
    HoldingRow? largest;
    var largestValue = 0.0;
    if (holdings != null &&
        rates != null &&
        summary != null &&
        summary.totalAssets > 0) {
      for (final holding in holdings) {
        final type = AssetType.fromStorage(holding.assetType);
        if (type == AssetType.liability) continue;
        final ccy = holding.currency.toUpperCase();
        if (ccy != 'CNY' && !isFxLinked(holding) && !rates.containsKey(ccy)) {
          largest = null;
          largestValue = 0;
          break;
        }
        final value =
            (type.isAmountBased
                ? holding.quantity
                : holding.quantity * holding.latestPrice) *
            valueRateOf(holding, rates);
        if (value > largestValue) {
          largest = holding;
          largestValue = value;
        }
      }
    }
    return AlertDialog(
      title: Text(widget.rule == null ? '添加提醒规则' : '编辑提醒规则'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<AlertRuleType>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: '提醒类型'),
                  items: [
                    for (final t in AlertRuleType.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: widget.rule != null
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() {
                              _type = value;
                              _followTarget = true;
                              _setFields();
                            });
                          }
                        },
                ),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: '规则名称（可选）'),
                ),
                if (_type == AlertRuleType.assetRatio) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('跟随资产配置目标'),
                    subtitle: Text(
                      _followTarget
                          ? (plan == null
                                ? '正在读取目标配置'
                                : '权益类目标 ${(plan[AssetCategory.equity] ?? 0).toStringAsFixed(1)}%')
                          : '使用此规则的自定义目标',
                    ),
                    value: _followTarget,
                    onChanged: (v) => setState(() => _followTarget = v),
                  ),
                  if (_followTarget)
                    Text('目标配置仅保存在本机，可通过备份转移；同步规则不会同步此目标。', style: T.label()),
                  if (!_followTarget)
                    TextFormField(
                      controller: _primary,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '权益类目标占比 %'),
                      validator: (v) => _number(v, min: 0, max: 100),
                    ),
                  TextFormField(
                    controller: _secondary,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '允许偏离（百分点）'),
                    validator: (v) => _number(v, min: 0, max: 100),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      equityPct == null
                          ? '当前权益占比：暂无数据'
                          : '当前权益占比：${equityPct.toStringAsFixed(1)}%',
                      style: T.label(),
                    ),
                  ),
                ] else if (_type == AlertRuleType.cashflow) ...[
                  TextFormField(
                    controller: _primary,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '每月日期（1–31）'),
                    validator: (v) =>
                        _number(v, min: 1, max: 31, integer: true),
                  ),
                  TextFormField(
                    controller: _secondary,
                    decoration: const InputDecoration(labelText: '事项名称（可选）'),
                  ),
                  TextFormField(
                    controller: _advance,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '提前天数（0–30）'),
                    validator: (v) =>
                        _number(v, min: 0, max: 30, integer: true),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('短月按最后一天处理'),
                    value: _shortMonth,
                    onChanged: (v) => setState(() => _shortMonth = v),
                  ),
                  Text('仅在 App 检查时触发；关闭 App 后不会定时检查。', style: T.label()),
                ] else ...[
                  TextFormField(
                    controller: _primary,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: _type == AlertRuleType.concentration
                          ? '单项持仓占比阈值 %'
                          : '组合单日跌幅阈值 %',
                    ),
                    validator: (v) => _number(v, min: 0, max: 100),
                  ),
                  if (_type == AlertRuleType.concentration)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        largest == null
                            ? '当前最大持仓占比：暂无完整数据'
                            : '当前最大持仓：${largest.name} · ${(largestValue / summary!.totalAssets * 100).toStringAsFixed(1)}%',
                        style: T.label(),
                      ),
                    ),
                  if (_type == AlertRuleType.drawdown)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        summary?.todayChangePct == null
                            ? '当前单日变化：暂无数据'
                            : '当前单日变化：${(summary!.todayChangePct! * 100).toStringAsFixed(2)}%',
                        style: T.label(),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
