import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/formats.dart';

void main() {
  group('holdingDuration', () {
    test('years and months', () {
      expect(
        Formats.holdingDuration(DateTime(2023, 1, 15), DateTime(2026, 8, 8)),
        '3年6个月',
      );
      expect(
        Formats.holdingDuration(DateTime(2024, 8, 8), DateTime(2026, 8, 8)),
        '2年',
      );
    });

    test('months only', () {
      expect(
        Formats.holdingDuration(DateTime(2026, 6, 1), DateTime(2026, 8, 8)),
        '2个月',
      );
      expect(
        Formats.holdingDuration(DateTime(2026, 7, 20), DateTime(2026, 8, 8)),
        '19天',
      );
    });

    test('borrowing days across month boundary', () {
      // Jan 31 -> Mar 1 should be 1个月 (with day borrow).
      expect(
        Formats.holdingDuration(DateTime(2026, 1, 31), DateTime(2026, 3, 1)),
        '1个月',
      );
    });

    test('same day', () {
      final d = DateTime(2026, 8, 8);
      expect(Formats.holdingDuration(d, d), '1天以内');
    });
  });

  group('plainNum', () {
    // Real values from the database: a unit cost is `invested ÷ shares`, so
    // it is a repeating decimal in binary and toString() leaks 16 digits.
    // The display form must cap it (see Formats.plainNum).
    test('caps the digits that division leaks', () {
      expect(Formats.plainNum(0.6307858439201451), '0.631');
      expect(Formats.plainNum(2.3510340909090908), '2.351');
      expect(Formats.plainNum(903.488747373734), '903.489');
      expect(Formats.plainNum(140.66332663652207), '140.663');
    });

    test('whole numbers stay bare, decimals are trimmed', () {
      expect(Formats.plainNum(275500), '275500');
      expect(Formats.plainNum(8800), '8800');
      expect(Formats.plainNum(0), '0');
      expect(Formats.plainNum(2.5), '2.5');
    });

    test('FX rates keep 4 decimals', () {
      expect(Formats.plainNum(7.1523412, decimals: 4), '7.1523');
    });

    test('stays parseable by double.tryParse', () {
      for (final v in const [0.6307858439201451, 275500.0, 0.0, 2.5, -3.7]) {
        expect(double.tryParse(Formats.plainNum(v)), isNotNull);
      }
    });

    test('display rounds — which is why it must never be written back', () {
      // Contract behind _parseEditable: the rounded display form is LOSSY,
      // so an untouched dialog field has to keep the stored double instead of
      // re-parsing this string, or mere "open + save" would alter the cost.
      const stored = 0.6307858439201451;
      expect(double.parse(Formats.plainNum(stored)), isNot(stored));
    });
  });

  group('annualizedReturn', () {
    test('one year -> equals total return', () {
      expect(Formats.annualizedReturn(0.12, 365), closeTo(0.12, 1e-9));
    });

    test('half year -> roughly doubled compound', () {
      final r = Formats.annualizedReturn(0.1, 182) ?? 0;
      // (1.1)^2 - 1 = 0.21
      expect(r, closeTo(0.21, 0.002));
    });

    test('two years -> square root of growth', () {
      // 21% over 2 years -> ~10%/yr
      expect(Formats.annualizedReturn(0.21, 730), closeTo(0.1, 0.001));
    });

    test('zero or negative days -> null', () {
      expect(Formats.annualizedReturn(0.1, 0), isNull);
      expect(Formats.annualizedReturn(0.1, -5), isNull);
    });

    test('total loss -> null', () {
      expect(Formats.annualizedReturn(-1.0, 365), isNull);
      expect(Formats.annualizedReturn(-1.5, 365), isNull);
    });
  });
}
