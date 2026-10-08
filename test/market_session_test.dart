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

  // Regression (2026-10-08): 0.10.3 added a statutory-holiday table that
  // wrongly listed 2026-10-08 as 国庆 (copying 2025's merged 中秋+国庆
  // 10/1-10/8), and the fetched calendar — cached during the break, newest
  // bar 09-30 — silently marked every later trading day closed. Result: the
  // UI showed 休市 and the day's A-share moves were dropped from today's
  // earnings (quoteChangeIsToday -> false).
  group('2026 国庆边界：10-08 起开市', () {
    final lastHoliday = DateTime(2026, 10, 7, 10);
    final firstDayBack = DateTime(2026, 10, 8, 14);

    setUp(() => setLiveTradingDays(null));
    tearDown(() => setLiveTradingDays(null));

    test('the static calendar knows 10-08 is a trading day', () {
      expect(isHoliday(firstDayBack), isFalse);
      expect(isTradingDay(firstDayBack), isTrue);
      expect(aShareSession(firstDayBack), MarketSession.open);
      expect(quoteChangeIsToday(firstDayBack, MarketSource.sina), isTrue);
      expect(quoteChangeIsToday(firstDayBack, MarketSource.eastmoney), isTrue);
    });

    test('10-01 .. 10-07 stay holidays', () {
      expect(isHoliday(DateTime(2026, 10, 1)), isTrue);
      expect(aShareSession(DateTime(2026, 10, 1, 10)), MarketSession.weekend);
      expect(aShareSession(lastHoliday), MarketSession.weekend);
      expect(quoteChangeIsToday(lastHoliday, MarketSource.sina), isFalse);
      // Gold / FX keep quoting through the holiday and must still count.
      expect(quoteChangeIsToday(lastHoliday, MarketSource.sge), isTrue);
    });

    test('a stale live calendar does not turn a later day into 休市', () {
      // Cache as left by a 10-01 fetch during the break (newest bar 09-30).
      setLiveTradingDays(
        {'2026-09-24', '2026-09-28', '2026-09-29', '2026-09-30'},
        coverageEnd: '2026-10-01',
      );
      expect(isTradingDay(firstDayBack), isTrue,
          reason: 'a date past the fetched window must not be asserted closed');
      expect(aShareSession(firstDayBack), MarketSession.open);
      expect(quoteChangeIsToday(firstDayBack, MarketSource.sina), isTrue);
      expect(quoteChangeIsToday(firstDayBack, MarketSource.eastmoney), isTrue);
    });

    test('inside the covered window the live calendar is authoritative', () {
      // 09-25 is inside the window but absent => a genuine closure.
      setLiveTradingDays(
        {'2026-09-24', '2026-09-28'},
        coverageEnd: '2026-09-30',
      );
      expect(isTradingDay(DateTime(2026, 9, 25, 14)), isFalse);
      expect(aShareSession(DateTime(2026, 9, 25, 14)), MarketSession.weekend);
      expect(isTradingDay(DateTime(2026, 9, 28, 14)), isTrue);
    });

    test('a live calendar that covers 10-08 keeps it open', () {
      setLiveTradingDays({'2026-10-08'}, coverageEnd: '2026-10-08');
      expect(isTradingDay(firstDayBack), isTrue);
      expect(aShareSession(firstDayBack), MarketSession.open);
    });

    test('coverage end defaults to the newest day in the set', () {
      setLiveTradingDays({'2026-09-30'});
      // 09-29 is inside the window but absent => authoritative "closed".
      expect(isTradingDay(DateTime(2026, 9, 29, 14)), isFalse);
      // 10-09 is past the newest day => the calendar cannot see it, so fall
      // back to weekday + holidays, which says open.
      expect(isTradingDay(DateTime(2026, 10, 9, 14)), isTrue);
    });
  });
}
