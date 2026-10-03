import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/market_session.dart';

void main() {
  // 2026-09-12 = Saturday, 09-13 = Sunday, 09-14 = Monday.
  final saturday = DateTime(2026, 9, 12, 10);
  final sunday = DateTime(2026, 9, 13, 10);
  final monday = DateTime(2026, 9, 14, 10);

  group('aShareSession', () {
    test('weekends are weekend regardless of the clock', () {
      expect(aShareSession(saturday), MarketSession.weekend);
      expect(aShareSession(DateTime(2026, 9, 12, 23, 59)), MarketSession.weekend);
      expect(aShareSession(sunday), MarketSession.weekend);
    });

    test('weekdays map to the A-share session timeline', () {
      expect(aShareSession(DateTime(2026, 9, 14, 8, 0)), MarketSession.preOpen);
      expect(aShareSession(DateTime(2026, 9, 14, 9, 30)), MarketSession.open);
      expect(aShareSession(DateTime(2026, 9, 14, 11, 45)), MarketSession.lunch);
      expect(aShareSession(DateTime(2026, 9, 14, 14, 0)), MarketSession.open);
      expect(aShareSession(DateTime(2026, 9, 14, 15, 30)), MarketSession.closed);
    });

    test('isWeekend only covers Saturday and Sunday', () {
      expect(isWeekend(saturday), isTrue);
      expect(isWeekend(sunday), isTrue);
      expect(isWeekend(monday), isFalse);
    });
  });

  group('quoteChangeIsToday', () {
    test('A-share quotes are today only while the session is live', () {
      expect(quoteChangeIsToday(monday, MarketSource.sina), isTrue);
      expect(quoteChangeIsToday(monday, MarketSource.eastmoney), isTrue);
      // Before the open the exchange still serves the previous session's
      // close pair, so its `change` is not today's move.
      expect(
        quoteChangeIsToday(
          DateTime(2026, 9, 14, 8),
          MarketSource.sina,
          session: MarketSession.preOpen,
        ),
        isFalse,
      );
    });

    test('weekend quotes belong to the previous session', () {
      for (final day in [saturday, sunday]) {
        expect(quoteChangeIsToday(day, MarketSource.sina), isFalse);
        expect(quoteChangeIsToday(day, MarketSource.eastmoney), isFalse);
        expect(quoteChangeIsToday(day, MarketSource.sge), isFalse);
        expect(quoteChangeIsToday(day, MarketSource.forex), isFalse);
      }
    });

    test('24/7 sources keep their change on weekends', () {
      expect(quoteChangeIsToday(saturday, MarketSource.coingecko), isTrue);
      expect(quoteChangeIsToday(sunday, MarketSource.coingecko), isTrue);
    });

    test('manual holdings never carry a market change', () {
      expect(quoteChangeIsToday(monday, MarketSource.manual), isFalse);
    });
  });

  group('A-share statutory holidays (2026)', () {
    test('国庆 weekday resolves to weekend without a session', () {
      // 2026-10-01 Thursday — National Day, A-share closed.
      final holiday = DateTime(2026, 10, 1, 10);
      expect(isHoliday(holiday), isTrue);
      expect(aShareSession(holiday), MarketSession.weekend);
      expect(isTradingDay(holiday), isFalse);
    });

    test('春节 / 清明 / 劳动节 weekdays are holidays too', () {
      expect(isTradingDay(DateTime(2026, 2, 16)), isFalse); // 春节
      expect(isTradingDay(DateTime(2026, 4, 6)), isFalse); // 清明
      expect(isTradingDay(DateTime(2026, 5, 1)), isFalse); // 劳动节
    });

    test('A-share quotes carry no change on a holiday', () {
      final holiday = DateTime(2026, 10, 1, 10);
      expect(
        quoteChangeIsToday(holiday, MarketSource.sina),
        isFalse,
        reason: 'A-share market is closed on National Day',
      );
      expect(
        quoteChangeIsToday(holiday, MarketSource.eastmoney),
        isFalse,
      );
    });

    test('24/7 sources still carry their change on A-share holidays', () {
      final holiday = DateTime(2026, 10, 1, 10);
      expect(quoteChangeIsToday(holiday, MarketSource.sge), isTrue,
          reason: 'gold trades around the clock on holidays');
      expect(quoteChangeIsToday(holiday, MarketSource.forex), isTrue,
          reason: 'FX moves on holidays and must count');
      expect(quoteChangeIsToday(holiday, MarketSource.coingecko), isTrue);
    });

    test('normal trading day is not a holiday', () {
      expect(isHoliday(monday), isFalse);
      expect(isTradingDay(monday), isTrue);
    });
  });
}
