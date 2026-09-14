// Live network verification of historical price endpoints.
// Skipped by default; run with:
//   flutter test --dart-define=LIVE=true test/live_history_sources_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/services/market/gold_fx_source.dart';
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
    'live: gold history (London spot converted to CNY/gram)',
    () async {
      final source = XauGoldHistorySource();
      final hist = await source.fetch('AU99.99', DateTime(2025, 1, 1), DateTime(2026, 8, 8));
      // ignore: avoid_print
      print('gold history days: ${hist.length}, sample: ${hist.entries.take(3).toList()}');
      expect(hist, isNotEmpty);
    },
    skip: !live,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // The regression guard for the mixed-instrument bug, against real
  // endpoints: the history must be derived from the same instrument the
  // live quote uses, so the newest historical day and the live quote agree
  // to within a fraction of a percent (intraday drift only). The Shanghai
  // gold futures contract this source used to read sits ~1% away, which is
  // what produced the fake daily return.
  test(
    'live: gold history agrees with the live gold quote',
    () async {
      final history = await XauGoldHistorySource()
          .fetch('AU99.99', DateTime(2025, 1, 1), DateTime(2026, 12, 31));
      final liveQuotes = await GoldFxSource().fetch(['XAU']);
      final liveQuote = liveQuotes.single;

      expect(history, isNotEmpty);
      expect(liveQuote.isSuccess, isTrue);

      final lastDate = history.keys.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
      final lastClose = history[lastDate]!;
      final diff = (liveQuote.price - lastClose).abs() / lastClose;
      // ignore: avoid_print
      print('live=${liveQuote.price} history[$lastDate]=$lastClose diff=${(diff * 100).toStringAsFixed(3)}%');

      expect(diff, lessThan(0.005));
    },
    skip: !live,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
