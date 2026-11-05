import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/symbols.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/market/market_data_source.dart';
import 'package:asset_tracker/services/market/market_service.dart';

/// Stub source answering every symbol with a fixed price.
class _FixedSource extends MarketDataSource {
  _FixedSource(super.source, this.price, {this.name = ''});

  final double price;
  final String name;

  @override
  Future<List<MarketQuote>> fetch(List<String> symbols) async => symbols
      .map((s) => MarketQuote(
            symbol: s,
            source: source,
            name: name,
            price: price,
            fetchedAt: DateTime.now(),
          ))
      .toList();
}

class _UppercaseSource extends _FixedSource {
  _UppercaseSource(super.source, super.price);

  @override
  Future<List<MarketQuote>> fetch(List<String> symbols) =>
      super.fetch(symbols.map((s) => s.toUpperCase()).toList());
}

void main() {
  late AppDatabase db;
  late AssetDao dao;

  /// One wall-clock reading per test run: the assertion below compares the
  /// freshly-written `fetched_at` against "today", and calling DateTime.now()
  /// twice straddles midnight often enough to flake CI.
  final runStart = DateTime.now();

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedFund({required double latestPrice}) async {
    final accountId = await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: accountId,
      name: '东方添益债券',
      assetType: AssetType.mutualFund.storageName,
      marketSource: Value(MarketSource.eastmoney.storageName),
      symbol: const Value('400030'),
      quantity: const Value(71310.81),
      costPrice: const Value(1.4553),
      latestPrice: Value(latestPrice),
      purchaseDate: Value(DateTime(2026, 1, 1)),
    ));
  }

  test('a quote from a colliding instrument is not written', () async {
    // 400030 is both the fund (NAV 1.4553) and the third-board stock 蓝璟5
    // (0.063). Fetching the fund from a stock endpoint produced a 23x error
    // that the write-back used to accept silently.
    await seedFund(latestPrice: 1.4553);
    final service = MarketService(dao, sources: {
      MarketSource.eastmoney:
          _FixedSource(MarketSource.eastmoney, 0.063, name: '蓝璟5'),
    });

    final result = await service.refreshAll();

    expect(result.updated, 0);
    expect(result.failed, 1);
    final holding = (await dao.getHoldings()).single;
    expect(holding.latestPrice, closeTo(1.4553, 1e-9),
        reason: '被拒收的行情不得覆盖上一个有效净值');
  });

  test('gold aliases match the adapter response regardless of case', () async {
    final account = await dao.createAccount(
        AccountsCompanion.insert(name: 'gold', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      accountId: account,
      name: 'gold',
      assetType: AssetType.gold.storageName,
      marketSource: Value(MarketSource.sge.storageName),
      symbol: const Value('xau'),
      quantity: const Value(1),
      latestPrice: const Value(700),
    ));
    final service = MarketService(dao, sources: {
      MarketSource.sge: _UppercaseSource(MarketSource.sge, 710),
    });
    final result = await service.refreshAll();
    expect(result.updated, 1);
    expect((await dao.getHoldings()).single.latestPrice, 710);
    final key = quoteCacheKey(MarketSource.sge, 'xau');
    expect((await dao.getCachedPrices([key]))[key]?.price, 710);
  });

  test('same symbol from different sources does not mix holding prices', () async {
    final account = await dao.createAccount(
        AccountsCompanion.insert(name: 'mixed', type: 'general'));
    for (final item in [
      (AssetType.mutualFund, MarketSource.eastmoney),
      (AssetType.mutualFund, MarketSource.coingecko),
    ]) {
      await dao.createHolding(HoldingsCompanion.insert(
        accountId: account,
        name: item.$2.storageName,
        assetType: item.$1.storageName,
        marketSource: Value(item.$2.storageName),
        symbol: const Value('same'),
        quantity: const Value(1),
        latestPrice: const Value(10),
      ));
    }
    final result = await MarketService(dao, sources: {
      MarketSource.eastmoney: _FixedSource(MarketSource.eastmoney, 11),
      MarketSource.coingecko: _FixedSource(MarketSource.coingecko, 12),
    }).refreshAll();
    expect(result.updated, 2);
    final holdings = await dao.getHoldings();
    expect(holdings.firstWhere((h) => h.marketSource == 'eastmoney').latestPrice, 11);
    expect(holdings.firstWhere((h) => h.marketSource == 'coingecko').latestPrice, 12);
    final cache = await dao.getCachedPrices(holdingQuoteCacheKeys(holdings));
    expect(cachedQuoteForHolding(cache, holdings.firstWhere((h) => h.marketSource == 'eastmoney'))?.price, 11);
    expect(cachedQuoteForHolding(cache, holdings.firstWhere((h) => h.marketSource == 'coingecko'))?.price, 12);
  });

  test('legacy cache is accepted only for its matching source', () async {
    await seedFund(latestPrice: 1.4553);
    final holding = (await dao.getHoldings()).single;
    await dao.upsertPriceCache(PriceCacheCompanion(
      symbol: const Value('400030'),
      source: Value(MarketSource.sina.storageName),
      name: const Value('other source'),
      price: const Value(2),
      currency: const Value('CNY'),
      fetchedAt: Value(DateTime.now()),
    ));
    var cache = await dao.getCachedPrices(holdingQuoteCacheKeys([holding]));
    expect(cachedQuoteForHolding(cache, holding) == null, isTrue);
    await dao.upsertPriceCache(PriceCacheCompanion(
      symbol: const Value('400030'),
      source: Value(MarketSource.eastmoney.storageName),
      name: const Value('legacy fund'),
      price: const Value(1.5),
      currency: const Value('CNY'),
      fetchedAt: Value(DateTime.now()),
    ));
    cache = await dao.getCachedPrices(holdingQuoteCacheKeys([holding]));
    expect(cachedQuoteForHolding(cache, holding)?.price, 1.5);
  });

  test('FX cache ignores unrelated old quote and uses new namespaced rate', () async {
    await dao.upsertPriceCache(PriceCacheCompanion(
      symbol: const Value('USD'),
      source: Value(MarketSource.coingecko.storageName),
      name: const Value('unrelated'),
      price: const Value(99),
      currency: const Value('CNY'),
      fetchedAt: Value(DateTime.now()),
    ));
    final service = MarketService(dao, sources: {
      MarketSource.forex: _FixedSource(MarketSource.forex, 7.2),
    });
    expect(await service.loadCnyRates(['USD']), {'USD': 7.2});
    expect(await service.loadCnyRates(['USD']), {'USD': 7.2});
    final key = quoteCacheKey(MarketSource.forex, 'USD');
    expect((await dao.getCachedPrices([key]))[key]?.price, 7.2);
  });

  test('an ordinary update is still written', () async {
    await seedFund(latestPrice: 1.4553);
    final service = MarketService(dao, sources: {
      MarketSource.eastmoney:
          _FixedSource(MarketSource.eastmoney, 1.4620, name: '东方添益债券'),
    });

    final result = await service.refreshAll();

    expect(result.updated, 1);
    expect(result.failed, 0);
    final holding = (await dao.getHoldings()).single;
    expect(holding.latestPrice, closeTo(1.4620, 1e-9));
  });

  test('a refresh that carries no move clears the previous change', () async {
    // The cache is a merge on conflict, so a quote that has a price but no
    // move (a fund endpoint with no NAVCHGRT, gold with no previous close)
    // used to leave the last session's change in place while still bumping
    // fetched_at — and the "written today" guard then handed that stale move
    // back as today's. Worst after the app has been shut for a while, when
    // the leftover value is weeks old.
    await seedFund(latestPrice: 1.4553);
    await dao.upsertPriceCache(PriceCacheCompanion(
      symbol: const Value('400030'),
      source: Value(MarketSource.eastmoney.storageName),
      name: const Value('东方添益债券'),
      price: const Value(1.4553),
      currency: const Value('CNY'),
      prevClose: const Value(1.4400),
      change: const Value(0.0153),
      changePct: const Value(1.06),
      fetchedAt: Value(DateTime(2026, 9, 1)),
    ));

    final service = MarketService(dao, sources: {
      MarketSource.eastmoney:
          _FixedSource(MarketSource.eastmoney, 1.4620, name: '东方添益债券'),
    });
    await service.refreshAll();

    final key = quoteCacheKey(MarketSource.eastmoney, '400030');
    final row = (await dao.getCachedPrices([key]))[key];
    // drift and flutter_test both export `isNull` / `isNotNull`, so assert
    // through plain booleans to avoid the ambiguous import.
    expect(row != null, isTrue);
    expect(row!.price, closeTo(1.4620, 1e-9));
    expect(row.change == null, isTrue,
        reason: '没有涨跌的新报价必须清掉上一次会话残留的 change');
    expect(row.prevClose == null, isTrue);
    expect(row.changePct == null, isTrue);
    expect(row.fetchedAt.day, runStart.day);
  });
}
