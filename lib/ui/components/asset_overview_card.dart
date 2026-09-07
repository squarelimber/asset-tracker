import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../tokens.dart';
import 'delta_text.dart';
import 'terminal_card.dart';

/// One "资产总览" card holding the whole balance-sheet snapshot:
/// 总资产 / 总负债 / 净资产 / 今日盈亏.
///
/// Desktop renders a single 4-column row, phone a 2x2 grid; cells are
/// separated by 1px hairlines (T.border) instead of four independent
/// cards, which saves vertical space on phone and reduces border noise.
class AssetOverviewCard extends StatelessWidget {
  const AssetOverviewCard({
    super.key,
    required this.totalAssets,
    required this.totalLiabilities,
    required this.netWorth,
    required this.todayProfit,
    this.todayPct,
    this.hidden = false,
  });

  final double totalAssets;
  final double totalLiabilities;
  final double netWorth;
  final double todayProfit;

  /// Day-over-day change of net worth, shown under 净资产.
  final double? todayPct;

  /// Mask all amounts (hide-amounts toggle).
  final bool hidden;

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
    final columns = desktop ? 4 : 2;

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
}
