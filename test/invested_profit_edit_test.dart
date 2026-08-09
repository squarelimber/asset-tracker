import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/features/holdings/invested_profit_field.dart';

void main() {
  testWidgets('edit scenario: change profit then clear focus, value survives', (tester) async {
    final amount = ValueNotifier<double>(50000);
    double? reported = 45000; // simulates investedResult initialized from DB
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InvestedProfitField(
          amount: amount,
          initialInvested: 45000,
          onChanged: (v) => reported = v,
        ),
      ),
    ));

    final investedField = tester.widget<TextField>(find.byType(TextField).at(0));
    final profitField = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(investedField.controller!.text, '45000');
    expect(profitField.controller!.text, '5000');

    // User edits the profit field: 5000 -> 8000.
    await tester.enterText(find.byType(TextField).at(1), '8000');
    await tester.pump();

    // The invested field must follow: 50000 - 8000 = 42000.
    expect(investedField.controller!.text, '42000');
    expect(reported, 42000);
  });

  testWidgets('edit scenario: clicking save button outside the field', (tester) async {
    final amount = ValueNotifier<double>(50000);
    double? reported = 45000;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            InvestedProfitField(
              amount: amount,
              initialInvested: 45000,
              onChanged: (v) => reported = v,
            ),
            FilledButton(
              onPressed: () {},
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    ));

    // Change profit, then tap the save button (focus leaves the text field).
    await tester.enterText(find.byType(TextField).at(1), '8000');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(reported, 42000);
  });

  testWidgets('decimal amounts survive parse (no thousands separator bug)', (tester) async {
    final amount = ValueNotifier<double>(21516.89);
    double? reported = 20429.1; // real-world values with decimals
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InvestedProfitField(
          amount: amount,
          initialInvested: 20429.1,
          onChanged: (v) => reported = v,
        ),
      ),
    ));

    // Initial prefill must be parseable (no commas).
    final investedField = tester.widget<TextField>(find.byType(TextField).at(0));
    expect(investedField.controller!.text, '20429.1');

    // Change profit -> invested must be a parseable plain number.
    await tester.enterText(find.byType(TextField).at(1), '500');
    await tester.pump();

    expect(investedField.controller!.text, '21016.89');
    expect(reported, closeTo(21016.89, 1e-6));
  });
}
