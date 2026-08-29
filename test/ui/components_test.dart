import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/ui/components/allocation_bars.dart';
import 'package:asset_tracker/ui/components/delta_text.dart';
import 'package:asset_tracker/ui/components/heat_cell.dart';
import 'package:asset_tracker/ui/components/terminal_card.dart';
import 'package:asset_tracker/ui/components/terminal_fab.dart';
import 'package:asset_tracker/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('top5WithOther merges tail into 其他', () {
    final entries = List.generate(
      7,
      (i) => AllocationEntry(label: 'P$i', color: T.accent, value: (i + 1) * 100, pct: (i + 1) / 28),
    );
    final segs = AllocationBars.top5WithOther(entries);
    expect(segs, hasLength(6));
    expect(segs[5].label, '其他');
    expect(segs[5].pct, closeTo(entries[5].pct + entries[6].pct, 1e-9));
    expect(AllocationBars.top5WithOther(entries.sublist(0, 5)), hasLength(5));
  });

  testWidgets('HeatCell colors by sign and intensity', (tester) async {
    BoxDecoration deco() =>
        tester
            .widget<Container>(
                find.descendant(of: find.byType(HeatCell), matching: find.byType(Container)).first)
            .decoration! as BoxDecoration;
    await tester.pumpWidget(const MaterialApp(home: SingleChildScrollView(child: HeatCell(value: 100, min: -50, max: 50))));
    expect(deco().color!.a, greaterThan(0));
    await tester.pumpWidget(const MaterialApp(home: SingleChildScrollView(child: HeatCell(value: -100, min: -50, max: 50))));
    expect(deco().color!.a, greaterThan(0));
    await tester.pumpWidget(const MaterialApp(home: SingleChildScrollView(child: HeatCell(value: 0, min: -50, max: 50))));
    expect(deco().color!.a, 0);
  });

  testWidgets('DeltaText uses red for positive', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DeltaText(value: 0.012)));
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.style!.color, T.up);
    expect(text.data, Formats.pct1(0.012));
  });

  testWidgets('TerminalCard renders bordered surface', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TerminalCard(child: Text('x'))));
    final container = tester.widget<Container>(
      find.descendant(of: find.byType(TerminalCard), matching: find.byType(Container)).first,
    );
    final deco = container.decoration! as BoxDecoration;
    expect(deco.color, T.surface);
    expect(deco.border!.top.color, T.border);
  });

  testWidgets('TerminalFab is flat accent button with label', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        floatingActionButton: TerminalFab(onPressed: null, icon: Icons.add, label: '添加'),
      ),
    ));
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.style!.backgroundColor!.resolve(const {}), T.accent);
    expect(button.style!.elevation!.resolve(const {}), 0);
    expect(find.text('添加'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });
}
