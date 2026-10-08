import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/market/trading_calendar_service.dart';

/// Always-failing client: an offline device, so the service must answer from
/// its cache plus the static weekday/holiday table.
http.Client _offline() => MockClient((_) async => http.Response('offline', 503));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late AssetDao dao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// Seeds the cache exactly as a fetch made on 2026-10-01 — i.e. in the
  /// middle of the National Day break — would leave it: the newest bar is
  /// 09-30, so the set knows nothing about 10-08.
  Future<void> seedHolidayFetch() async {
    await dao.setSetting(
      'a_share_calendar',
      '{"2026":["2026-09-24","2026-09-28","2026-09-29","2026-09-30"]}',
    );
    await dao.setSetting(
      'a_share_calendar_fetched_at',
      DateTime(2026, 10, 1, 13, 28).millisecondsSinceEpoch.toString(),
    );
  }

  test('a fetch made before a trading day does not mark it 休市', () async {
    await seedHolidayFetch();
    final service = TradingCalendarService(dao, client: _offline());

    expect(await service.coverageEndDay(), '2026-10-01');
    // 10-08 sits past the fetched window -> it must NOT be asserted closed.
    expect(await service.isTradingDay(DateTime(2026, 10, 8)), isTrue);
    // Inside the window the fetched set stays authoritative.
    expect(await service.isTradingDay(DateTime(2026, 9, 30)), isTrue);
    expect(await service.isTradingDay(DateTime(2026, 9, 25)), isFalse);
  });

  test('an empty cache falls back to weekday + static holidays', () async {
    final service = TradingCalendarService(dao, client: _offline());

    expect(await service.coverageEndDay(), isNull);
    expect(await service.isTradingDay(DateTime(2026, 10, 8)), isTrue);
    expect(await service.isTradingDay(DateTime(2026, 10, 1)), isFalse);
    expect(await service.isTradingDay(DateTime(2026, 10, 4)), isFalse); // Sun
  });

  test('a successful re-fetch merges and extends the covered window', () async {
    await seedHolidayFetch();
    final client = MockClient(
      (_) async => http.Response(
        '{"data":{"klines":["2026-09-30,3842.19","2026-10-08,3809.55"]}}',
        200,
      ),
    );
    final service = TradingCalendarService(dao, client: client);

    expect(await service.isTradingDay(DateTime(2026, 10, 8)), isTrue);
    final stored = await dao.getSetting('a_share_calendar') ?? '';
    expect(stored, contains('2026-09-24'),
        reason: 'merge must not drop previously cached days');
    expect(stored, contains('2026-10-08'));
    expect(
      (await service.coverageEndDay())!.compareTo('2026-10-08') >= 0,
      isTrue,
    );
  });

  test('a cache that already reaches today is not re-fetched', () async {
    // Window already covers today, so refreshing again is pure waste: no
    // request may hit the network.
    final today = DateTime.now();
    await dao.setSetting(
      'a_share_calendar',
      '{"${today.year}":["${todayKey(today)}"]}',
    );
    await dao.setSetting(
      'a_share_calendar_fetched_at',
      today.millisecondsSinceEpoch.toString(),
    );
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('{"data":{"klines":[]}}', 200);
    });
    final service = TradingCalendarService(dao, client: client);

    expect(await service.isTradingDay(today), isTrue);
    expect(calls, 0, reason: 'today was already fetched');
  });
}
