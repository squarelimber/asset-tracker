import 'package:flutter/material.dart';

import '../../components/day_earnings_panel.dart';
import '../../components/terminal_choice.dart';
import '../../tokens.dart';
import 'portfolio_intraday_card.dart';

/// Same daily explanation as the calendar, constrained for a modal sheet.
class DayDetailSheet extends StatefulWidget {
  const DayDetailSheet({super.key, required this.date, this.intradayKey});
  final DateTime date;
  final String? intradayKey;

  @override
  State<DayDetailSheet> createState() => _DayDetailSheetState();
}

class _DayDetailSheetState extends State<DayDetailSheet> {
  bool _showTrend = false;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.intradayKey != null) ...[
              Wrap(
                spacing: T.s2,
                children: [
                  TerminalChoice(
                    label: '收益明细',
                    selected: !_showTrend,
                    onPressed: () => setState(() => _showTrend = false),
                  ),
                  TerminalChoice(
                    label: '分时走势',
                    selected: _showTrend,
                    onPressed: () => setState(() => _showTrend = true),
                  ),
                ],
              ),
              const SizedBox(height: T.s2),
            ],
            if (_showTrend && widget.intradayKey != null)
              PortfolioIntradayTrend(day: widget.intradayKey!)
            else
              DayEarningsPanel(date: widget.date),
          ],
        ),
      ),
    ),
  );
}
