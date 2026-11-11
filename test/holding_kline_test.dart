import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_kline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  HoldingRow holding({
    required String type,
    required String? symbol,
    String currency = 'CNY',
    String source = 'sina',
  }) => HoldingRow(
    id: 1,
    accountId: 1,
    name: '持仓',
    assetType: type,
    marketSource: source,
    symbol: symbol,
    quantity: 1,
    costPrice: 1,
    latestPrice: 1,
    currency: currency,
    costRecorded: false,
    archived: false,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  test('识别 A 股和场内 ETF 代码，兼容手动定价', () {
    expect(
      klineSymbolForHolding(holding(type: 'stock', symbol: '600519')),
      'sh600519',
    );
    expect(
      klineSymbolForHolding(holding(type: 'stock', symbol: 'SZ000001')),
      'sz000001',
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'etf', symbol: '510300', source: 'manual'),
      ),
      'sh510300',
    );
    expect(
      klineSymbolForHolding(holding(type: 'etf', symbol: '159915')),
      'sz159915',
    );
  });

  test('识别北交所、港股、美股和 ETF，保留明确市场代码', () {
    expect(
      klineSymbolForHolding(holding(type: 'stock', symbol: '920003')),
      'bj920003',
    );
    expect(
      klineSymbolForHolding(holding(type: 'stock', symbol: 'BJ920003')),
      'bj920003',
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'stock', symbol: '00700', currency: 'HKD'),
      ),
      'hk00700',
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'stock', symbol: 'rt_hk00700', currency: 'HKD'),
      ),
      'hk00700',
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'etf', symbol: '2800', currency: 'HKD'),
      ),
      'hk02800',
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'stock', symbol: 'AAPL', currency: 'USD'),
      ),
      'usAAPL',
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'stock', symbol: 'gb_aapl', currency: 'USD'),
      ),
      'usAAPL',
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'etf', symbol: 'usSPY', currency: 'USD'),
      ),
      'usSPY',
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'etf', symbol: 'USO', currency: 'USD'),
      ),
      'usUSO',
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'stock', symbol: 'BRK.B.N', currency: 'USD'),
      ),
      'usBRK.B.N',
    );
  });

  test('场外基金、币种不匹配和不确定的代码保持原详情', () {
    expect(
      klineSymbolForHolding(holding(type: 'mutual_fund', symbol: '000001')),
      isNull,
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'stock', symbol: '00700', currency: 'CNY'),
      ),
      isNull,
    );
    expect(
      klineSymbolForHolding(holding(type: 'stock', symbol: 'sh000001')),
      isNull,
    );
    expect(klineSymbolForHolding(holding(type: 'stock', symbol: null)), isNull);
    expect(
      klineSymbolForHolding(holding(type: 'etf', symbol: 'sz510300')),
      isNull,
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'stock', symbol: '600519', currency: 'USD'),
      ),
      isNull,
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'stock', symbol: 'AAPL', currency: 'CNY'),
      ),
      isNull,
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'stock', symbol: 'hk00700', currency: 'USD'),
      ),
      isNull,
    );
    expect(
      klineSymbolForHolding(
        holding(type: 'stock', symbol: '600519', source: 'unknown'),
      ),
      isNull,
    );
    expect(
      klineSymbolForHolding(holding(type: 'stock', symbol: 'BJ430047')),
      'bj920047',
    );
    expect(
      klineSymbolForHolding(holding(type: 'stock', symbol: '430017')),
      'bj920017',
    );
    expect(
      klineSymbolForHolding(holding(type: 'stock', symbol: '430001')),
      isNull,
    );
  });
}
