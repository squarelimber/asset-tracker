import 'package:asset_tracker/core/global_market_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('A 股使用上海时区与交易所 2026 节假日', () {
    expect(
      quoteMarketSession(QuoteMarket.china, DateTime.utc(2026, 2, 23, 2)),
      QuoteMarketSession.holiday,
    );
    expect(
      quoteMarketSession(QuoteMarket.china, DateTime.utc(2026, 11, 9, 2)),
      QuoteMarketSession.open,
    );
    expect(
      quoteMarketSession(QuoteMarket.china, DateTime.utc(2026, 11, 9, 4)),
      QuoteMarketSession.lunch,
    );
  });
  test('港股包含节假日及半日市', () {
    expect(
      quoteMarketSession(QuoteMarket.hongKong, DateTime.utc(2026, 10, 19, 2)),
      QuoteMarketSession.holiday,
    );
    expect(
      quoteMarketSession(
        QuoteMarket.hongKong,
        DateTime.utc(2026, 12, 24, 4, 30),
      ),
      QuoteMarketSession.closed,
    );
    expect(
      quoteMarketSession(
        QuoteMarket.hongKong,
        DateTime.utc(2026, 11, 9, 4, 30),
      ),
      QuoteMarketSession.lunch,
    );
  });
  test('日股午休、收盘与日本假日', () {
    expect(
      quoteMarketSession(QuoteMarket.japan, DateTime.utc(2026, 9, 22, 1)),
      QuoteMarketSession.holiday,
    );
    expect(
      quoteMarketSession(QuoteMarket.japan, DateTime.utc(2026, 11, 9, 3)),
      QuoteMarketSession.lunch,
    );
    expect(
      quoteMarketSession(QuoteMarket.japan, DateTime.utc(2026, 11, 9, 6, 30)),
      QuoteMarketSession.closed,
    );
  });
  test('美股夏令时、冬令时和提前收盘', () {
    expect(
      quoteMarketSession(QuoteMarket.us, DateTime.utc(2026, 7, 6, 13, 30)),
      QuoteMarketSession.open,
    );
    expect(
      quoteMarketSession(QuoteMarket.us, DateTime.utc(2026, 11, 9, 14)),
      QuoteMarketSession.preOpen,
    );
    expect(
      quoteMarketSession(QuoteMarket.us, DateTime.utc(2026, 11, 9, 14, 30)),
      QuoteMarketSession.open,
    );
    expect(
      quoteMarketSession(QuoteMarket.us, DateTime.utc(2026, 11, 27, 18)),
      QuoteMarketSession.closed,
    );
    expect(
      quoteMarketSession(QuoteMarket.us, DateTime.utc(2026, 12, 25, 16)),
      QuoteMarketSession.holiday,
    );
  });
  test('缺少日历和品种交易时段时不猜测', () {
    expect(
      quoteMarketSession(QuoteMarket.us, DateTime.utc(2027, 1, 4, 16)),
      QuoteMarketSession.unknown,
    );
    expect(
      quoteMarketSession(QuoteMarket.commodity, DateTime.utc(2026, 11, 9)),
      QuoteMarketSession.unknown,
    );
  });
}
