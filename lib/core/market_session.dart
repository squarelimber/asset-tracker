/// Trading-session helpers derived from the local clock.
///
/// Lives in `core/` (not in the UI) because the session is not just a
/// label: a cached quote's `change` field describes a *session*, and
/// outside that session it must not be presented as today's change. See
/// [quoteChangeIsToday].
library;

import 'enums.dart';

/// A-share trading session derived from the local clock.
///
/// No holiday calendar is consulted: a holiday still reads as 未开盘/已收盘.
enum MarketSession { preOpen, open, lunch, closed, weekend }

MarketSession aShareSession([DateTime? now]) {
  final n = now ?? DateTime.now();
  if (n.weekday == DateTime.saturday || n.weekday == DateTime.sunday) {
    return MarketSession.weekend;
  }
  final t = n.hour * 60 + n.minute;
  if (t >= 9 * 60 + 30 && t < 11 * 60 + 30) return MarketSession.open;
  if (t >= 13 * 60 && t < 15 * 60) return MarketSession.open;
  if (t < 9 * 60 + 30) return MarketSession.preOpen;
  if (t < 13 * 60) return MarketSession.lunch;
  return MarketSession.closed;
}

/// Whether [day] is a weekend (the only non-trading day this app knows
/// about — there is no holiday calendar).
bool isWeekend(DateTime day) =>
    day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;

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
///   open the exchange still serves the previous session's close pair.
/// - [MarketSource.sge] / [MarketSource.forex] (gold, FX): quoted nearly
///   around the clock on business days, so only weekends are excluded.
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
