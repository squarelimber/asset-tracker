import 'package:asset_tracker/ui/components/allocation_bars.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AllocationBars target (plan) rendering', () {
    testWidgets('target percentage renders as ratio-based "40.0%" not "4000%"',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AllocationBars(
            entries: const [
              AllocationEntry(
                label: '股票',
                color: Colors.red,
                value: 3500,
                pct: 0.35,
                targetPct: 0.4,
              ),
            ],
          ),
        ),
      ));

      // Target comes from the plan as a 0..1 ratio: 0.4 -> 40.0%, never 4000%.
      expect(find.textContaining('目标 40.0%'), findsOneWidget);
      expect(find.text('4000.0%'), findsNothing);
      // Deviation = actual - target in percentage points (-5pp).
      expect(find.textContaining('偏差 -5.0%'), findsOneWidget);
    });

    testWidgets('entry without a target shows no plan line', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AllocationBars(
            entries: const [
              AllocationEntry(
                label: '现金',
                color: Colors.blue,
                value: 1000,
                pct: 0.1,
              ),
            ],
          ),
        ),
      ));

      expect(find.textContaining('目标'), findsNothing);
      expect(find.textContaining('偏差'), findsNothing);
    });
  });
}