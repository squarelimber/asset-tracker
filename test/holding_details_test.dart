import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_details.dart';
import 'package:asset_tracker/services/market/history_source.dart';

class _FakeHistorySource extends HistoryDataSource {
  _FakeHistorySource() : super(MarketSource.eastmoney);

  final Map<String, DailyPriceHistory> data = {};

  static String key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Future<DailyPriceHistory> fetch(String symbol, DateTime from, DateTime to) async {
    return data[symbol] ?? {};
  }
}

void main() {
  late AppDatabase db;
  late AssetDao dao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> addHolding({
    required String name,
    required AssetType type,
    double quantity = 0,
    double costPrice = 0,
    double latestPrice = 0,
    String? symbol,
    DateTime? purchaseDate,
  }) async {
    final accountId = await dao.createAccount(
      AccountsCompanion.insert(name: '账户', type: 'general'),
    );
    return dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: name,
      assetType: type.storageName,
      marketSource: Value(type.isMarketLinked ? 'eastmoney' : 'manual'),
      symbol: symbol == null ? const Value.absent() : Value(symbol),
      quantity: Value(quantity),
      costPrice: Value(costPrice),
      latestPrice: Value(latestPrice),
      purchaseDate: Value(purchaseDate ?? DateTime(2026, 1, 1)),
    ));
  }

  test('computes per-holding breakdown for a day', () async {
    await addHolding(
      name: '基金A', type: AssetType.mutualFund,
      quantity: 100, costPrice: 2.5, latestPrice: 2.6, symbol: '110022',
    );
    await addHolding(
      name: '基金B', type: AssetType.mutualFund,
      quantity: 200, costPrice: 3.0, latestPrice: 3.2, symbol: '005827',
    );
    await addHolding(
      name: '现金', type: AssetType.bankDeposit,
      quantity: 5000, costPrice: 5000, latestPrice: 1,
    );

    final fake = _FakeHistorySource();
    fake.data['110022'] = {_FakeHistorySource.key(DateTime(2026, 7, 2)): 2.7};
    fake.data['005827'] = {_FakeHistorySource.key(DateTime(2026, 7, 2)): 3.1};

    final service = HoldingDetailService(dao, sources: {MarketSource.eastmoney: fake});
    final detail = await service.compute(DateTime(2026, 7, 2));

    expect(detail, isNotNull);
    expect(detail!.date, '2026-07-02');
    expect(detail.items, hasLength(3));

    final a = detail.items.firstWhere((i) => i.holding.name == '基金A');
    expect(a.price, 2.7);
    expect(a.marketValue, closeTo(270, 1e-6));
    expect(a.cost, closeTo(250, 1e-6));
    expect(a.ratio, closeTo(270 / 5890, 1e-9));

    final cash = detail.items.firstWhere((i) => i.holding.name == '现金');
    expect(cash.marketValue, 5000);
    expect(cash.price, 1);

    // Total = 270 + 620 + 5000.
    expect(detail.totalValue, closeTo(5890, 1e-6));
  });

  test('holdings not owned yet on the day are excluded', () async {
    await addHolding(
      name: '新基金', type: AssetType.mutualFund,
      quantity: 100, costPrice: 2.0, latestPrice: 2.0, symbol: '110022',
      purchaseDate: DateTime(2026, 7, 5),
    );
    final fake = _FakeHistorySource();
    fake.data['110022'] = {_FakeHistorySource.key(DateTime(2026, 7, 2)): 2.0};

    final service = HoldingDetailService(dao, sources: {MarketSource.eastmoney: fake});
    final detail = await service.compute(DateTime(2026, 7, 2));
    // Bought 07-05 -> not in the 07-02 breakdown.
    expect(detail, isNull);
  });

  test('liabilities are listed and reduce total value', () async {
    await addHolding(
      name: '现金', type: AssetType.bankDeposit,
      quantity: 1000, costPrice: 1000, latestPrice: 1,
    );
    await addHolding(
      name: '贷款', type: AssetType.liability,
      quantity: 300, costPrice: 300, latestPrice: 1,
    );
    final service = HoldingDetailService(dao, sources: {});
    final detail = await service.compute(DateTime(2026, 7, 2));
    expect(detail!.totalValue, closeTo(700, 1e-6));
    expect(detail.items, hasLength(2));
    final loan = detail.items.firstWhere((i) => i.holding.name == '贷款');
    expect(loan.marketValue, 300);
  });

  test('result is cached for repeat queries', () async {
    await addHolding(
      name: '现金', type: AssetType.bankDeposit,
      quantity: 1000, costPrice: 1000, latestPrice: 1,
    );
    final service = HoldingDetailService(dao, sources: {});
    final d1 = await service.compute(DateTime(2026, 7, 2));
    final d2 = await service.compute(DateTime(2026, 7, 2));
    expect(identical(d1, d2), isTrue);
  });

  test('weekend detail uses the last trading day price (forward fill)', () async {
    await addHolding(
      name: '基金', type: AssetType.mutualFund,
      quantity: 100, costPrice: 2.0, latestPrice: 2.6, symbol: '110022',
    );
    final fake = _FakeHistorySource();
    // Only Friday 2026-07-03 has history; the latest price is 2.6.
    fake.data['110022'] = {_FakeHistorySource.key(DateTime(2026, 7, 3)): 2.1};

    final service = HoldingDetailService(dao, sources: {MarketSource.eastmoney: fake});
    // 2026-07-04 is a Saturday: must resolve to Friday's 2.1, NOT 2.6.
    final detail = await service.compute(DateTime(2026, 7, 4));
    expect(detail, isNotNull);
    final item = detail!.items.single;
    expect(item.price, 2.1);
    expect(item.marketValue, closeTo(210, 1e-6));
  });

  test('foreign currency holdings are converted into CNY in the total', () async {
    await addHolding(
      name: '美元现金', type: AssetType.bankDeposit,
      quantity: 1000, costPrice: 1000, latestPrice: 1,
    ).then((id) async {
      final stmt = db.update(db.holdings)..where((t) => t.id.equals(id));
      await stmt.write(const HoldingsCompanion(currency: Value('USD')));
    });
    await addHolding(
      name: '人民币现金', type: AssetType.bankDeposit,
      quantity: 2000, costPrice: 2000, latestPrice: 1,
    );

    final service = HoldingDetailService(dao, sources: {});
    final detail = await service.compute(
      DateTime(2026, 7, 4),
      cnyRates: {'USD': 7.2},
    );
    expect(detail, isNotNull);
    // Total = 1000*7.2 + 2000 = 9200 CNY (NOT 3000).
    expect(detail!.totalValue, closeTo(9200, 1e-6));
    final usd = detail.items.firstWhere((i) => i.holding.name == '美元现金');
    expect(usd.marketValue, 1000); // own currency kept
    expect(usd.marketValueCny, closeTo(7200, 1e-6));
    expect(usd.ratio, closeTo(7200 / 9200, 1e-9));
  });
}
