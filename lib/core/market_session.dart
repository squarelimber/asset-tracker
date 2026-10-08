/// Trading-session helpers derived from the local clock.
///
/// Lives in `core/` (not in the UI) because the session is not just a
/// label: a cached quote's `change` field describes a *session*, and
/// outside that session it must not be presented as today's change. See
/// [quoteChangeIsToday].
library;

import 'enums.dart';
import 'formats.dart';

/// A-share trading session derived from the local clock.
///
/// Weekends and statutory A-share holidays resolve as [MarketSession.weekend]
/// (休市). Sources that keep quoting outside the A-share calendar — gold,
/// FX, crypto — are *not* gated by this: they price around the clock, so
/// their moves still show on holidays (see [quoteChangeIsToday]).
enum MarketSession { preOpen, open, lunch, closed, weekend }

/// A-share statutory market closures that fall on weekdays, as calendar dates
/// (yyyy-MM-dd). Weekends are handled separately by [isWeekend]; note that a
/// 调休补班 weekend still finds the A-share market closed, so it must NOT be
/// added here (it is already excluded by the weekday test).
///
/// Based on the State Council's official holiday schedule — 2026: 元旦
/// 1/1-1/3, 春节 2/15-2/21, 清明 4/4-4/6, 劳动节 5/1-5/5, 端午 6/19-6/21,
/// 中秋 9/25-9/27, 国庆 10/1-10/7 (10/8 起照常开市). Extend per-year as
/// announced — and do NOT copy the previous year's arrangement: 2025 merged
/// 中秋 and 国庆 into 10/1-10/8, which is what wrongly marked 2026-10-08 as a
/// holiday here.
///
/// This set is the SINGLE source of truth for the static table; the trading
/// calendar service's offline fallback imports [isHoliday] instead of keeping
/// a second copy (the two copies had drifted apart).
const Set<String> _aShareHolidayDates = {
  // 2026
  '2026-01-01', '2026-01-02', // 元旦 (1/3 = Saturday)
  '2026-02-16', '2026-02-17', '2026-02-18', '2026-02-19',
  '2026-02-20', // 春节 (2/15 Sun, 2/21 Sat)
  '2026-04-06', // 清明 (4/4 Sat, 4/5 Sun, 4/6 Mon)
  '2026-05-01', '2026-05-04', '2026-05-05', // 劳动节 (5/2-5/3 weekend)
  '2026-06-19', // 端午 (6/19 Fri, 6/20-6/21 weekend)
  '2026-09-25', // 中秋 (9/25 Fri, 9/26-9/27 weekend)
  '2026-10-01', '2026-10-02', '2026-10-05', '2026-10-06',
  '2026-10-07', // 国庆 (10/3-10/4 weekend); 10/8(周四) 起照常开市
};

/// Whether [day] falls on an A-share holiday (weekday holidays only).
bool isHoliday(DateTime day) => _aShareHolidayDates.contains(todayKey(day));

/// Live trading-day set loaded from the Eastmoney calendar service, keyed by
/// 'yyyy-MM-dd'. When non-null it overrides the static weekend + holiday
/// approximation for exact 调休 handling.
Set<String>? _liveTradingDays;

/// Newest date the live calendar can legitimately speak for ('yyyy-MM-dd').
///
/// The fetched calendar is *history*: a fetch made on 10-01 knows nothing
/// about 10-08. Past this date the set must not be used to assert "closed" —
/// otherwise every trading day after the last fetch reads as 休市. That is
/// exactly the 2026-10-08 regression: the calendar had been fetched during
/// the National Day break, so its newest bar was 09-30.
String? _liveCalendarCoverageEnd;

/// Installs the fetched A-share trading-day set (yyyy-MM-dd) so
/// [aShareSession] / [isTradingDay] use the authoritative calendar *within the
/// window it actually covers*. Pass null to clear (revert to the static
/// fallback).
///
/// [coverageEnd] is the newest date the fetch can speak for — normally the
/// fetch date. It defaults to the newest date in [days].
void setLiveTradingDays(Set<String>? days, {String? coverageEnd}) {
  _liveTradingDays = days;
  if (days == null || days.isEmpty) {
    _liveCalendarCoverageEnd = null;
    return;
  }
  var end = days.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  if (coverageEnd != null && coverageEnd.compareTo(end) > 0) end = coverageEnd;
  _liveCalendarCoverageEnd = end;
}

/// Whether [day] is covered by the installed live calendar. Only then may the
/// set be used to answer "is this a trading day?".
bool _liveCalendarCovers(DateTime day) {
  final end = _liveCalendarCoverageEnd;
  if (end == null) return false;
  return todayKey(day).compareTo(end) <= 0;
}

/// Whether [day] is known NOT to be an A-share trading day.
///
/// Inside the fetched calendar's window the set is authoritative (it encodes
/// 调休 exactly). Outside it — or with no calendar at all — fall back to
/// weekday + statutory holidays. A date the calendar cannot see must never be
/// asserted as closed.
bool _isNonTradingDay(DateTime day) {
  final live = _liveTradingDays;
  if (live != null && _liveCalendarCovers(day)) {
    return !live.contains(todayKey(day));
  }
  return isWeekend(day) || isHoliday(day);
}

MarketSession aShareSession([DateTime? now]) {
  final n = now ?? DateTime.now();
  if (_isNonTradingDay(n)) return MarketSession.weekend;
  final t = n.hour * 60 + n.minute;
  if (t >= 9 * 60 + 30 && t < 11 * 60 + 30) return MarketSession.open;
  if (t >= 13 * 60 && t < 15 * 60) return MarketSession.open;
  if (t < 9 * 60 + 30) return MarketSession.preOpen;
  if (t < 13 * 60) return MarketSession.lunch;
  return MarketSession.closed;
}

/// Whether [day] is a weekend (Saturdays/Sundays, A-share always closed).
bool isWeekend(DateTime day) =>
    day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;

/// Whether the A-share market trades on [day]. Uses the live fetched calendar
/// within its coverage window, otherwise weekday + static holidays.
bool isTradingDay(DateTime day) => !_isNonTradingDay(day);

/// Whether a cached quote's `change` / `changePct` describes [day] itself
/// for a holding priced by [source].
///
/// The quote is fetched from an exchange that only restates it while it is
/// trading, so outside the session the cached `change` still describes the
/// *previous* session. Presenting it as "today's" change double-counts that
/// session on the next day — the reason a weekend used to show a full
/// trading day's P&L in the holdings list.
///
/// Rules per source:
/// - [MarketSource.sina] / [MarketSource.eastmoney] (A-shares, ETFs, funds):
///   only while the A-share session is actually quoting today — before the
///   open the exchange still serves the previous session's close pair. A
///   statutory holiday (no session at all) resolves to 休市 the same way as
///   a weekend, so these moves are not credited to the holiday.
/// - [MarketSource.sge] / [MarketSource.forex] (gold, FX): quoted nearly
///   around the clock on business days, so only weekends are excluded —
///   holidays still move the price and the move counts as today's.
/// - [MarketSource.coingecko]: 24/7, always today's change.
/// - [MarketSource.manual]: no quote at all; there is nothing to attribute.
bool quoteChangeIsToday(
  DateTime day,
  MarketSource source, {
  MarketSession? session,
}) {
  switch (source) {
    case MarketSource.manual:
      return false;
    case MarketSource.coingecko:
      return true;
    case MarketSource.sge:
    case MarketSource.forex:
      return !isWeekend(day);
    case MarketSource.sina:
    case MarketSource.eastmoney:
      final s = session ?? aShareSession(day);
      return s != MarketSession.weekend && s != MarketSession.preOpen;
  }
}
