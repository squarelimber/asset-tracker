import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/formats.dart';
import '../../core/market_session.dart' as session;
import '../../data/asset_dao.dart';

/// A-share trading-day calendar, fetched from the Eastmoney composite-index
/// kline feed (each bar = one trading day, so statutory holidays and 调休 are
/// inherently reflected) and cached locally per year.
///
/// Two rules keep the cache honest:
///  * it is refreshed at most once a day, because a fetch made *before* a
///    trading day simply cannot contain it;
///  * it only answers for the window it covers — see [coverageEndDay]. Past
///    that window [isTradingDay] falls back to the static weekday + holiday
///    table ([session.isHoliday]) instead of asserting "closed", which would
///    turn every trading day after the last fetch into 休市.
///
/// The device can be offline long-term, so a failed fetch silently keeps
/// whatever is cached.
class TradingCalendarService {
  TradingCalendarService(this._dao, {http.Client? client})
    : _client = client ?? http.Client();

  final AssetDao _dao;
  final http.Client _client;

  static const _base = 'https://push2his.eastmoney.com/api/qt/stock/kline/get';
  // Shanghai composite (000001, secid 1.000001): its daily bars are the
  // authoritative A-share trading-day list.
  static const _secId = '1.000001';
  static const _settingsKeyCalendar = 'a_share_calendar';
  static const _settingsKeyFetched = 'a_share_calendar_fetched_at';

  final Map<int, Set<String>> _cacheYears = {};

  /// Whether the A-share market trades on [day]. Uses the fetched calendar
  /// when it covers [day]; otherwise falls back to weekday + static holidays.
  Future<bool> isTradingDay(DateTime day) async {
    final year = day.year;
    var set = await _calendarFor(year);
    // Attempt a refresh when the year is missing *or* the cache is too old to
    // speak for [day] (a fetch made before a trading day cannot contain it).
    // _maybeFetchYear itself skips when today's fetch already happened.
    if (set == null || !await _covers(day)) {
      await _maybeFetchYear(year);
      set = await _calendarFor(year);
    }
    if (set != null && await _covers(day)) {
      return set.contains(todayKey(day));
    }
    // Fallback: weekday and not a statutory holiday.
    return !session.isWeekend(day) && !session.isHoliday(day);
  }

  /// Newest date the cached fetch can speak for ('yyyy-MM-dd'): the later of
  /// the fetch date and the newest stored trading day. Null when nothing was
  /// ever fetched.
  ///
  /// Callers installing the calendar into [session.setLiveTradingDays] must
  /// pass this as `coverageEnd` so dates past the fetch are not judged by a
  /// calendar that cannot know about them.
  Future<String?> coverageEndDay() async {
    String? end;
    final ms = int.tryParse(await _dao.getSetting(_settingsKeyFetched) ?? '');
    if (ms != null) {
      end = todayKey(DateTime.fromMillisecondsSinceEpoch(ms));
    }
    final all = await _loadAll();
    for (final list in all.values) {
      for (final d in list) {
        if (end == null || d.compareTo(end) > 0) end = d;
      }
    }
    return end;
  }

  Future<bool> _covers(DateTime day) async {
    final end = await coverageEndDay();
    if (end == null) return false;
    return todayKey(day).compareTo(end) <= 0;
  }

  /// Fetches (and caches) the trading days of [year] when they are missing or
  /// the cache predates today. Also rolls over: on/after Dec 1 the *next* year
  /// is fetched so the new year's holiday calendar is ready before it starts.
  Future<void> _maybeFetchYear(int year) async {
    final now = DateTime.now();
    final needsNext = now.month == 12 && year == now.year + 1;
    final hasData = await _calendarFor(year) != null;
    // Refresh at most once per day: a same-day cache is as fresh as this feed
    // gets, but yesterday's fetch cannot know about today's session.
    if (hasData && await _fetchedToday()) return;
    try {
      await _fetchAndCache(year);
      if (needsNext) {
        await _fetchAndCache(now.year + 1);
      }
    } catch (_) {
      // Offline / transient failure: keep the static fallback.
    }
  }

  Future<bool> _fetchedToday() async {
    final ms = int.tryParse(await _dao.getSetting(_settingsKeyFetched) ?? '');
    if (ms == null) return false;
    final fetched = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    return fetched.year == now.year &&
        fetched.month == now.month &&
        fetched.day == now.day;
  }

  Future<void> _fetchAndCache(int year) async {
    final uri = Uri.parse(_base).replace(
      queryParameters: {
        'secid': _secId,
        'fields1': 'f1,f2,f3,f4,f5,f6',
        'fields2': 'f51',
        'klt': '101',
        'fqt': '0',
        'beg': '${year}0101',
        'end': '${year + 1}0101',
        'lmt': '366',
      },
    );
    final resp = await _client.get(uri).timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return;
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>?;
    if (data == null) return;
    final klines = data['klines'] as List<dynamic>?;
    if (klines == null || klines.isEmpty) return;
    final days = <String>{
      for (final k in klines)
        if (k is String) k.split(',')[0],
    };
    if (days.isEmpty) return;

    // Merge with what is already persisted: a re-fetch must never shrink a
    // year that was fetched more completely before.
    final byYear = await _loadAll();
    final merged = <String>{...?byYear[year.toString()], ...days};
    _cacheYears[year] = merged;
    byYear[year.toString()] = merged.toList()..sort();
    await _dao.setSetting(_settingsKeyCalendar, jsonEncode(byYear));
    await _dao.setSetting(
      _settingsKeyFetched,
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  Future<Set<String>?> _calendarFor(int year) async {
    final hit = _cacheYears[year];
    if (hit != null) return hit;
    final all = await _loadAll();
    final list = all[year.toString()];
    if (list == null || list.isEmpty) return null;
    final set = Set<String>.of(list);
    _cacheYears[year] = set;
    return set;
  }

  /// All cached trading days across years, as a flat 'yyyy-MM-dd' set.
  /// Empty when nothing was fetched yet (offline first run).
  Future<Set<String>> allTradingDays() async {
    final all = await _loadAll();
    final out = <String>{};
    for (final list in all.values) {
      out.addAll(list);
    }
    _cacheYears.clear();
    for (final e in all.entries) {
      _cacheYears[int.parse(e.key)] = Set<String>.of(e.value);
    }
    return out;
  }

  Future<Map<String, List<String>>> _loadAll() async {
    try {
      final raw = await _dao.getSetting(_settingsKeyCalendar);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      return decoded.map(
        (k, v) => MapEntry(k, (v as List<dynamic>).cast<String>()),
      );
    } catch (_) {
      return {};
    }
  }
}
