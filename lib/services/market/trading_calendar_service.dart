import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/formats.dart';
import '../../data/asset_dao.dart';

/// A-share trading-day calendar, fetched from the Eastmoney composite-index
/// kline feed (each bar = one trading day, so statutory holidays and 调休 are
/// inherently reflected) and cached locally per year.
///
/// The device can be offline long-term, so [isTradingDay] falls back to a
/// static weekday + statutory-holiday table (see core/market_session.dart)
/// when the fetched calendar is unavailable. The fetch is cheap and is
/// attempted lazily (first open of a year / the December rollover), so the
/// live calendar replaces the static approximation as soon as it arrives.
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
  /// when available; otherwise falls back to weekday + static holidays.
  Future<bool> isTradingDay(DateTime day) async {
    final year = day.year;
    var set = await _calendarFor(year);
    if (set == null) {
      await _maybeFetchYear(year);
      set = await _calendarFor(year);
    }
    if (set != null) {
      return set.contains(todayKey(day));
    }
    // Fallback: weekday and not a statutory holiday.
    if (day.weekday == DateTime.saturday || day.weekday == DateTime.sunday) {
      return false;
    }
    return !_isStaticHoliday(day);
  }

  /// Fetches (and caches) the trading days of [year] when they are not yet
  /// present. Also rolls over: on/after Dec 1 the *next* year is fetched so
  /// the new year's holiday calendar is ready before it starts.
  Future<void> _maybeFetchYear(int year) async {
    final now = DateTime.now();
    final needsNext = now.month == 12 && year == now.year + 1;
    if (await _calendarFor(year) != null) return;
    try {
      await _fetchAndCache(year);
      if (needsNext) {
        await _fetchAndCache(now.year + 1);
      }
    } catch (_) {
      // Offline / transient failure: keep the static fallback.
    }
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
    _cacheYears[year] = days;

    // Persist only if this year is complete enough to be useful; partial
    // years (e.g. fetched mid-year) are still fine for judging today.
    final existing = await _calendarFor(year);
    final merged = existing ?? <String>{};
    merged.addAll(days);
    _cacheYears[year] = merged;

    final byYear = await _loadAll();
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

/// Static statutory-holiday fallback (weekdays the A-share market is closed).
/// Keep in sync with core/market_session.dart's _aShareHolidayDates.
bool _isStaticHoliday(DateTime day) {
  const dates = <String>{
    // 2026
    '2026-01-01', '2026-01-02',
    '2026-02-16', '2026-02-17', '2026-02-18', '2026-02-19', '2026-02-20',
    '2026-04-06',
    '2026-05-01', '2026-05-04', '2026-05-05',
    '2026-06-19',
    '2026-09-25',
    '2026-10-01', '2026-10-02', '2026-10-05', '2026-10-06', '2026-10-07',
    '2026-10-08',
  };
  return dates.contains(todayKey(day));
}
