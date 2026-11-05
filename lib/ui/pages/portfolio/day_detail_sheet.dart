import 'package:flutter/material.dart';

import '../../components/day_earnings_panel.dart';

/// Same daily explanation as the calendar, constrained for a modal sheet.
class DayDetailSheet extends StatelessWidget {
  const DayDetailSheet({super.key, required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: DayEarningsPanel(date: date),
      ),
    ),
  );
}
