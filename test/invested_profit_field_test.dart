import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/ui/pages/holdings/invested_profit_field.dart';

void main() {
  testWidgets('fields stay empty when no invested amount recorded', (tester) async {
    final amount = ValueNotifier<double>(50000);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InvestedProfitField(
          amount: amount,
          initialInvested: null,
          onChanged: (_) {},
        ),
      ),
    ));

    // Setting the amount alone must NOT prefill invested/profit.
    final investedField = tester.widget<TextField>(find.byType(TextField).at(0));
    final profitField = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(investedField.controller!.text, isEmpty);
    expect(profitField.controller!.text, isEmpty);
  });

  testWidgets('profit input derives invested and reports it', (tester) async {
    final amount = ValueNotifier<double>(50000);
    double? reported;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InvestedProfitField(
          amount: amount,
          initialInvested: null,
          onChanged: (v) => reported = v,
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField).at(1), '5000');
    await tester.pump();

    final investedField = tester.widget<TextField>(find.byType(TextField).at(0));
    expect(investedField.controller!.text, '45000');
    expect(reported, 45000);
  });

  testWidgets('invested input derives profit', (tester) async {
    final amount = ValueNotifier<double>(50000);
    double? reported;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InvestedProfitField(
          amount: amount,
          initialInvested: null,
          onChanged: (v) => reported = v,
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField).at(0), '45000');
    await tester.pump();

    final profitField = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(profitField.controller!.text, '5000');
    expect(reported, 45000);
  });

  testWidgets('amount change after profit input re-derives invested', (tester) async {
    final amount = ValueNotifier<double>(0);
    double? reported;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InvestedProfitField(
          amount: amount,
          initialInvested: null,
          onChanged: (v) => reported = v,
        ),
      ),
    ));

    // Enter profit first (amount still 0 -> no derivation yet).
    await tester.enterText(find.byType(TextField).at(1), '5000');
    await tester.pump();
    // Then the user fills in the amount.
    amount.value = 50000;
    await tester.pump();

    final investedField = tester.widget<TextField>(find.byType(TextField).at(0));
    expect(investedField.controller!.text, '45000');
    expect(reported, 45000);
  });

  testWidgets('clearing profit after deriving does not report stale invested', (tester) async {
    final amount = ValueNotifier<double>(50000);
    final reported = <double?>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InvestedProfitField(
          amount: amount,
          initialInvested: null,
          onChanged: (v) => reported.add(v),
        ),
      ),
    ));

    // Derive invested from profit.
    await tester.enterText(find.byType(TextField).at(1), '5000');
    await tester.pump();
    expect(reported.last, 45000);

    // User clears the invested field -> nothing stale should be emitted.
    await tester.enterText(find.byType(TextField).at(0), '');
    await tester.pump();
    expect(reported.last, isNull);
  });
}
