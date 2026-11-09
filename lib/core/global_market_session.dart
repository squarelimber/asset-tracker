/// Regular equity-session status. Inputs are instants, independent of the
/// device's timezone. The 2026 calendars are exchange-published schedules.
enum QuoteMarket { china, hongKong, japan, us, commodity, forex }

enum QuoteMarketSession { open, lunch, preOpen, closed, holiday, unknown }

String quoteMarketSessionLabel(QuoteMarketSession session) => switch (session) {
  QuoteMarketSession.open => '交易中',
  QuoteMarketSession.lunch => '午休',
  QuoteMarketSession.preOpen => '未开盘',
  QuoteMarketSession.closed => '已收盘',
  QuoteMarketSession.holiday => '休市',
  QuoteMarketSession.unknown => '状态未知',
};

// https://www.sse.com.cn/disclosure/dealinstruc/closed/
const _chinaHolidays2026 = {
  '01-01',
  '01-02',
  '02-16',
  '02-17',
  '02-18',
  '02-19',
  '02-20',
  '02-23',
  '04-06',
  '05-01',
  '05-04',
  '05-05',
  '06-19',
  '09-25',
  '10-01',
  '10-02',
  '10-05',
  '10-06',
  '10-07',
};

// https://www.hkex.com.hk/-/media/HKEX-Market/Services/Circulars-and-Notices/Participant-and-Members-Circulars/SEHK/2025/ce_SEHK_CT_075_2025.pdf
const _hkHolidays2026 = {
  '01-01',
  '02-17',
  '02-18',
  '02-19',
  '04-03',
  '04-06',
  '04-07',
  '05-01',
  '05-25',
  '06-19',
  '07-01',
  '10-01',
  '10-19',
  '12-25',
};
const _hkEarlyClose2026 = {'02-16', '12-24', '12-31'};

// https://www.jpx.co.jp/english/corporate/about-jpx/calendar/index.html
const _japanHolidays2026 = {
  '01-01',
  '01-02',
  '01-12',
  '02-11',
  '02-23',
  '03-20',
  '04-29',
  '05-04',
  '05-05',
  '05-06',
  '07-20',
  '08-11',
  '09-21',
  '09-22',
  '09-23',
  '10-12',
  '11-03',
  '11-23',
  '12-31',
};

// https://www.nyse.com/trade/hours-calendars
const _usHolidays2026 = {
  '01-01',
  '01-19',
  '02-16',
  '04-03',
  '05-25',
  '06-19',
  '07-03',
  '09-07',
  '11-26',
  '12-25',
};
const _usEarlyClose2026 = {'11-27', '12-24'};

QuoteMarketSession quoteMarketSession(QuoteMarket market, [DateTime? now]) {
  if (market == QuoteMarket.commodity || market == QuoteMarket.forex) {
    return QuoteMarketSession.unknown;
  }
  final utc = (now ?? DateTime.now()).toUtc();
  final offset = switch (market) {
    QuoteMarket.china || QuoteMarket.hongKong => 8,
    QuoteMarket.japan => 9,
    QuoteMarket.us => _isUsDaylightTime(utc) ? -4 : -5,
    _ => 0,
  };
  // Keep UTC flag so calendar arithmetic is independent of the device zone.
  final local = utc.add(Duration(hours: offset));
  if (local.weekday == DateTime.saturday || local.weekday == DateTime.sunday) {
    return QuoteMarketSession.holiday;
  }
  // Do not infer holiday schedules for years not yet verified.
  if (local.year != 2026) return QuoteMarketSession.unknown;
  final key =
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
  final holidays = switch (market) {
    QuoteMarket.china => _chinaHolidays2026,
    QuoteMarket.hongKong => _hkHolidays2026,
    QuoteMarket.japan => _japanHolidays2026,
    QuoteMarket.us => _usHolidays2026,
    _ => const <String>{},
  };
  if (holidays.contains(key)) return QuoteMarketSession.holiday;
  final minutes = local.hour * 60 + local.minute;
  if (market == QuoteMarket.us) {
    final close = _usEarlyClose2026.contains(key) ? 13 * 60 : 16 * 60;
    if (minutes < 9 * 60 + 30) return QuoteMarketSession.preOpen;
    return minutes < close
        ? QuoteMarketSession.open
        : QuoteMarketSession.closed;
  }
  final morningStart = market == QuoteMarket.japan ? 9 * 60 : 9 * 60 + 30;
  final morningEnd = market == QuoteMarket.hongKong ? 12 * 60 : 11 * 60 + 30;
  final afternoonStart = market == QuoteMarket.japan ? 12 * 60 + 30 : 13 * 60;
  final close = switch (market) {
    QuoteMarket.china => 15 * 60,
    QuoteMarket.hongKong => 16 * 60,
    QuoteMarket.japan => 15 * 60 + 30,
    _ => 0,
  };
  if (minutes < morningStart) return QuoteMarketSession.preOpen;
  if (minutes < morningEnd) return QuoteMarketSession.open;
  if (market == QuoteMarket.hongKong && _hkEarlyClose2026.contains(key)) {
    return QuoteMarketSession.closed;
  }
  if (minutes < afternoonStart) return QuoteMarketSession.lunch;
  return minutes < close ? QuoteMarketSession.open : QuoteMarketSession.closed;
}

bool _isUsDaylightTime(DateTime utc) {
  final marchFirst = DateTime.utc(utc.year, 3, 1);
  final secondSunday = 1 + (DateTime.sunday - marchFirst.weekday) % 7 + 7;
  final novemberFirst = DateTime.utc(utc.year, 11, 1);
  final firstSunday = 1 + (DateTime.sunday - novemberFirst.weekday) % 7;
  final start = DateTime.utc(utc.year, 3, secondSunday, 7);
  final end = DateTime.utc(utc.year, 11, firstSunday, 6);
  return !utc.isBefore(start) && utc.isBefore(end);
}
