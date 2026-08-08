// Live network verification of historical price endpoints.
// Skipped by default; run with:
//   flutter test --dart-define=LIVE=true test/live_history_sources_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/services/market/history_source.dart';

const live = bool.fromEnvironment('LIVE');

void main() {
  test(
    'live: eastmoney fund NAV history',
    () async {
      final source = EastmoneyHistorySource();
      final hist = await source.fetch('110022', DateTime(2026, 7, 1), DateTime(2026, 8, 8));
      // ignore: avoid_print
      print('fund history days: ${hist.length}, sample: ${hist.entries.take(3).toList()}');
      expect(hist, isNotEmpty);
    },
    skip: !live,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'live: sina stock daily K-line',
    () async {
      final source = SinaKLineSource();
      final hist = await source.fetch('sh600519', DateTime(2025, 1, 1), DateTime(2026, 8, 8));
      // ignore: avoid_print
      print('stock history days: ${hist.length}, sample: ${hist.entries.take(3).toList()}');
      expect(hist, isNotEmpty);
    },
    skip: !live,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'live: shanghai gold futures history',
    () async {
      final source = AuGoldHistorySource();
      final hist = await source.fetch('AU99.99', DateTime(2025, 1, 1), DateTime(2026, 8, 8));
      // ignore: avoid_print
      print('gold history days: ${hist.length}, sample: ${hist.entries.take(3).toList()}');
      expect(hist, isNotEmpty);
    },
    skip: !live,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
