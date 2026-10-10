import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
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

void main() {
  late AppDatabase db;
  late AssetDao dao;

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
}
