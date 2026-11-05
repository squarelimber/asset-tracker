// Isolated, synthetic data for visual review. Never opens the production DB.
import 'dart:math' as math;

import 'package:asset_tracker/app/app.dart';
import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/services/market/market_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase(
    driftDatabase(
      name: 'asset_tracker_design_preview',
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    ),
  );
  final dao = AssetDao(db);
  if ((await dao.getHoldings()).isEmpty) await _seed(dao);
  if (await dao.getSetting('preview_snapshot_v2') != '1') {
    await _writePreviewSnapshots(dao);
    await dao.setSetting('preview_snapshot_v2', '1');
  }
  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        hideAmountsProvider.overrideWith((ref) => false),
        historySyncProvider.overrideWith((ref) async => null),
        marketServiceProvider.overrideWithValue(_PreviewMarket(dao)),
      ],
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: Banner(
          message: '演示数据',
          location: BannerLocation.topEnd,
          color: Color(0xFF5B4D34),
          textDirection: TextDirection.ltr,
          child: AssetTrackerApp(),
        ),
      ),
    ),
  );
}

double _value(HoldingRow h) =>
    AssetType.fromStorage(h.assetType).isAmountBased ||
        h.assetType == 'liability'
    ? h.quantity
    : h.quantity * h.latestPrice;
double _cost(HoldingRow h) => AssetType.fromStorage(h.assetType).isAmountBased
    ? h.costPrice
    : h.quantity * h.costPrice;

Future<void> _seed(AssetDao dao) async {
  final securities = await dao.createAccount(
    AccountsCompanion.insert(name: '证券账户', type: 'general'),
  );
  final bank = await dao.createAccount(
    AccountsCompanion.insert(name: '银行账户', type: 'bank'),
  );
  final items = [
    (
      name: '沪深300ETF',
      type: 'etf',
      symbol: '510300',
      quantity: 40000.0,
      cost: 3.86,
      price: 4.125,
      category: 'equity',
    ),
    (
      name: '中证红利ETF',
      type: 'etf',
      symbol: '515080',
      quantity: 26000.0,
      cost: 3.08,
      price: 3.26,
      category: 'equity',
    ),
    (
      name: '五年期国债ETF',
      type: 'etf',
      symbol: '511010',
      quantity: 1000.0,
      cost: 106.84,
      price: 108.32,
      category: 'bond',
    ),
    (
      name: '黄金ETF',
      type: 'etf',
      symbol: '518880',
      quantity: 9000.0,
      cost: 7.13,
      price: 7.82,
      category: 'gold',
    ),
    (
      name: '纯债基金',
      type: 'mutual_fund',
      symbol: '000001',
      quantity: 60000.0,
      cost: 1.0621,
      price: 1.0948,
      category: 'bond',
    ),
    (
      name: '银行定期存款',
      type: 'bank_deposit',
      symbol: '',
      quantity: 125000.0,
      cost: 125000.0,
      price: 1.0,
      category: 'cash',
    ),
    (
      name: '活期理财',
      type: 'liquid_wealth',
      symbol: '',
      quantity: 58000.0,
      cost: 57200.0,
      price: 1.0,
      category: 'cash',
    ),
    (
      name: '银行活期',
      type: 'savings',
      symbol: '',
      quantity: 27000.0,
      cost: 27000.0,
      price: 1.0,
      category: 'cash',
    ),
    (
      name: '信用卡待还',
      type: 'liability',
      symbol: '',
      quantity: 12580.0,
      cost: 1.0,
      price: 1.0,
      category: 'cash',
    ),
  ];
  final now = DateTime.now();
  for (final (index, item) in items.indexed) {
    final account = index < 5 ? securities : bank;
    final id = await dao.createHolding(
      HoldingsCompanion.insert(
        accountId: account,
        name: item.name,
        assetType: item.type,
        symbol: Value(item.symbol.isEmpty ? null : item.symbol),
        quantity: Value(item.quantity),
        costPrice: Value(item.cost),
        latestPrice: Value(item.price),
        categoryOverride: Value(item.category),
        costRecorded: const Value(true),
        purchaseDate: Value(now.subtract(const Duration(days: 100))),
      ),
    );
    if (item.type != 'liability') {
      final amount = AssetType.fromStorage(item.type).isAmountBased
          ? item.cost
          : item.quantity * item.cost;
      await dao.createTransaction(
        TransactionsCompanion.insert(
          accountId: account,
          holdingId: Value(id),
          type: 'buy',
          amount: amount,
          quantity: Value(item.quantity),
          price: Value(item.cost),
          occurredAt: now.subtract(const Duration(days: 100)),
        ),
      );
    }
  }
  await dao.setSetting('notifications_enabled', 'false');
}

Future<void> _writePreviewSnapshots(AssetDao dao) async {
  final holdings = await dao.getHoldings();
  final assets = holdings.where((h) => h.assetType != 'liability');
  final total = assets.fold(0.0, (v, h) => v + _value(h));
  final cost = assets.fold(0.0, (v, h) => v + _cost(h));
  final debt = holdings
      .where((h) => h.assetType == 'liability')
      .fold(0.0, (v, h) => v + _value(h));
  final now = DateTime.now();
  for (var day = 90; day >= 0; day--) {
    final progress = (90 - day) / 90;
    final change =
        -19000 * (1 - progress) +
        math.sin(progress * 20) * 1000 * (1 - progress);
    final values = [
      for (final h in holdings)
        DayHoldingValue(
          holdingId: h.id,
          name: h.name,
          type: AssetType.fromStorage(h.assetType),
          value:
              _value(h) +
              (h.assetType == 'liability' ? 0 : change * _value(h) / total),
          cost: h.assetType == 'liability' ? 0 : _cost(h),
          liability: h.assetType == 'liability',
        ),
    ];
    await dao.upsertSnapshot(
      SnapshotsCompanion.insert(
        date: Formats.date(now.subtract(Duration(days: day))),
        totalValue: total + change - debt,
        totalCost: cost,
        liabilities: Value(debt),
        holdingValues: Value(encodeHoldingValues(values)),
      ),
    );
  }
}

class _PreviewMarket extends MarketService {
  _PreviewMarket(super.dao);
  @override
  Future<MarketRefreshResult> refreshAll() async =>
      MarketRefreshResult(updated: 0, failed: 0, fetchedAt: DateTime.now());
}
