import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../tokens.dart';
import 'delta_text.dart';
import 'terminal_card.dart';

/// One "资产总览" card holding the whole balance-sheet snapshot:
/// 总资产 / 总负债 / 净资产 / 今日盈亏.
///
/// Desktop renders a single 4-column row with 1px hairlines between the
/// cells. Phone renders a bank-card layout: a dark gradient card whose
/// hero cell is 净资产 with 今日盈亏 right beside the main value, and a
/// muted footer line carrying 总资产 / 总负债.
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
  });

  final double totalAssets;
  final double totalLiabilities;
  final double netWorth;
  final double todayProfit;

  /// Day-over-day change of net worth, shown under 净资产.
  final double? todayPct;

  /// Mask all amounts (hide-amounts toggle).
  final bool hidden;

  /// Toggles amount visibility; when present the card renders an eye button
  /// in its top-right corner (the phone bank-card layout only). Null keeps
  /// the card non-interactive (the app-bar eye on wide screens).
  final VoidCallback? onToggleHidden;

  String _amount(double v) => hidden ? Formats.masked() : Formats.amount(v);

  Border? _borders(int index, bool desktop) {
    final side = const BorderSide(color: T.border, width: 1);
    if (desktop) {
      return index > 0 ? Border(left: side) : null;
    }
    // 2x2: 0 总资产, 1 总负债, 2 净资产, 3 今日盈亏
    return switch (index) {
      1 => Border(left: side),
      2 => Border(top: side),
      3 => Border(top: side, left: side),
      _ => null,
    };
  }

  Widget _cell(String label, String text, {Color? color, bool hero = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: T.label()),
          const SizedBox(height: T.s1),
          Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: T.mono(
              size: hero ? 24 : 20,
              weight: hero ? FontWeight.w700 : FontWeight.w600,
              color: color ?? T.text1,
            ),
          ),
          if (hero && todayPct != null) ...[
            const SizedBox(height: T.s1),
            DeltaText(value: todayPct!),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 1100;
    if (!desktop) {
      return _buildBankCard(context);
    }

    const columns = 4;

    final cells = <Widget>[
      _cell('总资产', _amount(totalAssets)),
      _cell('总负债', _amount(totalLiabilities), color: T.text2),
      _cell('净资产', _amount(netWorth), hero: true),
      _cell(
        '今日盈亏',
        '${todayProfit >= 0 ? '+' : ''}${_amount(todayProfit)}',
        color: T.changeColor(todayProfit),
      ),
    ];

    final rows = <List<Widget>>[];
    for (var i = 0; i < cells.length; i += columns) {
      rows.add(cells.sublist(
        i,
        i + columns > cells.length ? cells.length : i + columns,
      ));
    }

    return TerminalCard(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var r = 0; r < rows.length; r++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var c = 0; c < rows[r].length; c++)
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: _borders(r * columns + c, desktop),
                        ),
                        child: rows[r][c],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Phone: bank-card layout — 深色渐变 + 圆角大卡，净资产为主角。
  Widget _buildBankCard(BuildContext context) {
    // 深蓝 → 深紫的暗渐变，保持终端深色调；右上一团淡光晕模拟卡面反光。
    const gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF1C2740), // 深靛蓝
        Color(0xFF25203E), // 深蓝紫
        Color(0xFF26203A), // 暗紫
      ],
      stops: [0.0, 0.55, 1.0],
    );

    String pctText() {
      final pct = todayPct;
      if (pct == null) return '';
      return '${pct >= 0 ? '+' : ''}${Formats.pct1(pct)}';
    }

    // 主数值右边的今日盈亏标：金额（掩码隐藏时只显示 pct）。
    Widget profitBadge() {
      final color = T.changeColor(todayProfit);
      final text = hidden
          ? (todayPct == null ? Formats.masked() : pctText())
          : '${todayProfit >= 0 ? '+' : ''}${Formats.amount(todayProfit)}'
              '${todayPct == null ? '' : '  ${pctText()}'}';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(T.rPill),
        ),
        child: Text(
          text,
          maxLines: 1,
          style: T.mono(size: 12, weight: FontWeight.w700, color: color),
        ),
      );
    }

    return Container(
      // 与 TerminalCard 相同的圆角/边框语言，但外层自绘渐变。
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: T.border),
        boxShadow: const [
          // 右上一团微光，模拟卡面高光且不破坏深色基调。
          BoxShadow(
            color: Color(0x2458A6FF), // accent 14% 上发光
            offset: Offset(-24, -18),
            blurRadius: 48,
          ),
          BoxShadow(
            color: Color(0x143E2A66),
            offset: Offset(20, 18),
            blurRadius: 60,
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('净资产', style: T.label(size: 12, color: T.text2)),
              const Spacer(),
              if (onToggleHidden != null)
                IconButton(
                  tooltip: hidden ? '显示金额' : '隐藏金额',
                  visualDensity: VisualDensity.compact,
                  onPressed: onToggleHidden,
                  icon: Icon(
                    hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 18,
                    color: T.text2,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // 主行：主数值 + 今日盈亏 pill。主数值放在固定高度容器里，
          // FittedBox 只负责宽度方向等比缩小——隐藏（¥•••••）与显示长
          // 金额时卡片高度恒定，不会“一会儿大一会儿小”。
          Row(
            children: [
              Flexible(
                child: SizedBox(
                  height: 36,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _amount(netWorth),
                      maxLines: 1,
                      style: T.mono(
                        size: 26,
                        weight: FontWeight.w700,
                        color: T.text1,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              profitBadge(),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '总资产 ${_compact(totalAssets)} · 负债 ${_compact(totalLiabilities)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.mono(size: 12, color: T.text2),
          ),
        ],
      ),
    );
  }

  /// 底部小字用紧凑金额（太长会吃掉整行宽度）。
  String _compact(double v) =>
      hidden ? Formats.masked() : Formats.amountCompact(v);
}