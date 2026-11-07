import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../tokens.dart';

/// Balance-sheet panel. Amounts share a baseline and never wrap across lines.
class AssetOverviewCard extends StatelessWidget {
  const AssetOverviewCard({
    super.key,
    required this.totalAssets,
    required this.totalLiabilities,
    required this.netWorth,
    required this.todayProfit,
    this.todayPct,
    this.hidden = false,
    this.onToggleHidden,
    this.onOpenEarnings,
  });

  final double totalAssets;
  final double totalLiabilities;
  final double netWorth;
  final double? todayProfit;
  final double? todayPct;
  final bool hidden;
  final VoidCallback? onToggleHidden;
  final VoidCallback? onOpenEarnings;

  String _amount(double value) =>
      hidden ? Formats.masked() : Formats.amount(value);
  Color get _profitColor =>
      todayProfit == null ? T.text3 : T.changeColor(todayProfit!);
  String get _profit => todayProfit == null
      ? '--'
      : hidden
      ? Formats.masked()
      : '${todayProfit! >= 0 ? '+' : ''}${Formats.amount(todayProfit!)}';
  String? get _percentage => todayPct == null
      ? null
      : '${todayPct! >= 0 ? '+' : ''}${Formats.pct(todayPct!)}';

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF263341), Color(0xFF22272F)],
        ),
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: T.border),
      ),
      child: wide ? _desktop() : _compact(),
    );
  }

  Widget _desktop() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Text(
            '资产总览',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: T.s3),
          Text('CNY', style: T.mono(size: 11, color: T.text2)),
          const Spacer(),
          if (onOpenEarnings != null)
            TextButton.icon(
              onPressed: onOpenEarnings,
              icon: const Icon(Icons.calendar_month_outlined, size: 16),
              label: const Text('收益日历'),
            ),
          if (onToggleHidden != null) _privacyButton(),
        ],
      ),
      const SizedBox(height: 20),
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: _metric('净资产', _amount(netWorth), size: 28),
            ),
            _divider(),
            Expanded(
              flex: 2,
              child: _earningsAction(
                _metric(
                  '今日盈亏',
                  _profit,
                  color: _profitColor,
                  detail: _percentage,
                  opensDetails: onOpenEarnings != null,
                ),
              ),
            ),
            _divider(),
            Expanded(flex: 2, child: _metric('总资产', _amount(totalAssets))),
            _divider(),
            Expanded(
              flex: 2,
              child: _metric('总负债', _amount(totalLiabilities), color: T.text2),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _compact() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text('净资产', style: T.label(size: 12)),
          const SizedBox(width: 8),
          Text('CNY', style: T.mono(size: 10, color: T.text2)),
          const Spacer(),
          if (onOpenEarnings != null)
            IconButton(
              tooltip: '收益日历',
              onPressed: onOpenEarnings,
              icon: const Icon(Icons.calendar_month_outlined, size: 18),
            ),
          if (onToggleHidden != null) _privacyButton(),
        ],
      ),
      _number(_amount(netWorth), size: 28),
      const SizedBox(height: 14),
      _earningsAction(
        Row(
          children: [
            _metricLabel('今日盈亏', opensDetails: onOpenEarnings != null),
            const SizedBox(width: T.s2),
            Flexible(child: _number(_profit, size: 14, color: _profitColor)),
            if (_percentage != null) ...[
              const SizedBox(width: 8),
              Text(_percentage!, style: T.mono(size: 11, color: _profitColor)),
            ],
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Divider(height: 1),
      ),
      Row(
        children: [
          Expanded(child: _metric('总资产', _amount(totalAssets), size: 16)),
          const SizedBox(width: 20),
          Expanded(
            child: _metric(
              '总负债',
              _amount(totalLiabilities),
              size: 16,
              color: T.text2,
            ),
          ),
        ],
      ),
    ],
  );

  Widget _privacyButton() => IconButton(
    tooltip: hidden ? '显示金额' : '隐藏金额',
    isSelected: hidden,
    onPressed: onToggleHidden,
    icon: const Icon(Icons.visibility_outlined, size: 18),
    selectedIcon: const Icon(Icons.visibility_off_outlined, size: 18),
  );

  Widget _divider() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 20),
    child: VerticalDivider(width: 1, color: T.borderSoft),
  );

  Widget _earningsAction(Widget child) => onOpenEarnings == null
      ? child
      : Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onOpenEarnings,
            borderRadius: BorderRadius.circular(T.rInput),
            child: Tooltip(
              message: '查看当日收益明细',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: child,
              ),
            ),
          ),
        );

  Widget _number(String text, {required double size, Color? color}) => SizedBox(
    height: size + 8,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        maxLines: 1,
        style: T.mono(size: size, weight: FontWeight.w500, color: color),
      ),
    ),
  );

  Widget _metric(
    String label,
    String value, {
    double size = 22,
    Color? color,
    String? detail,
    bool opensDetails = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _metricLabel(label, opensDetails: opensDetails),
      const SizedBox(height: 8),
      _number(value, size: size, color: color),
      if (detail != null) ...[
        const SizedBox(height: 4),
        Text(detail, style: T.mono(size: 11, color: color)),
      ],
    ],
  );

  Widget _metricLabel(String label, {required bool opensDetails}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: T.label()),
      if (opensDetails)
        const Icon(Icons.chevron_right, color: T.text2, size: 14),
    ],
  );
}
