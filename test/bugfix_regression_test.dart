import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/daily_earnings.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:asset_tracker/domain/target_allocation.dart';
import 'package:asset_tracker/domain/transaction_service.dart';
import 'package:asset_tracker/services/backup_service.dart';

/// Regression tests for the 2026-09-11 bug-report fixes:
/// M1/M3 (transaction guards), M5 (rate denominator), M10/M11 (target
/// allocation), H4 (replay window), C2 (backup effective ids).
void main() {
  group('TransactionService guards', () {
    late AssetDao dao;
    late TransactionService service;
    late int accountId;
    late int cashId;
    late int stockId;

    setUp(() async {
      final db = AppDatabase(NativeDatabase.memory());
      dao = AssetDao(db);
      service = TransactionService(dao);
      accountId = await dao.createAccount(AccountsCompanion.insert(name: 'A', type: 'general'));
      cashId = await dao.createHolding(HoldingsCompanion.insert(
        accountId: accountId,
        name: '零钱',
        assetType: 'savings',
        marketSource: const Value('manual'),
        quantity: const Value(10000),
        costPrice: const Value(10000),
        latestPrice: const Value(1),
      ));
      stockId = await dao.createHolding(HoldingsCompanion.insert(
        accountId: accountId,
        name: '股票',
        assetType: 'stock',
        marketSource: const Value('sina'),
        symbol: const Value('sh600519'),
        quantity: const Value(100),
        costPrice: const Value(10),
        latestPrice: const Value(12),
      ));
      // Keep the executor alive for the test body.
      addTearDown(db.close);
    });

    test('transfer cannot overdraw the source balance (M1)', () async {
      final bankId = await dao.createHolding(HoldingsCompanion.insert(
        accountId: accountId,
        name: '存款',
        assetType: 'bank_deposit',
        marketSource: const Value('manual'),
        quantity: const Value(500),
        costPrice: const Value(500),
        latestPrice: const Value(1),
      ));
      final result = await service.record(
        accountId: accountId,
        type: TransactionType.transferOut,
        amount: 20000,
        cashSourceId: cashId,
        cashTargetId: bankId,
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('余额不足'));
      // Nothing moved.
      expect((await dao.getHolding(cashId))!.quantity, 10000);
    });

    test('transfer rejects source == target (M1 cost-drift)', () async {
      final result = await service.record(
        accountId: accountId,
        type: TransactionType.transferOut,
        amount: 100,
        cashSourceId: cashId,
        cashTargetId: cashId,
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('不能是同一持仓'));
    });

    test('deleting a non-latest split is rejected (M3)', () async {
      final service = TransactionService(dao);
      await service.record(
        accountId: accountId,
        holdingId: stockId,
        type: TransactionType.buy,
        quantity: 100,
        price: 20,
        amount: 2000,
      );
      final splitResult = await service.record(
        accountId: accountId,
        holdingId: stockId,
        type: TransactionType.split,
        amount: 2,
      );
      expect(splitResult.ok, isTrue);
      await service.record(
        accountId: accountId,
        holdingId: stockId,
        type: TransactionType.buy,
        quantity: 50,
        price: 8,
        amount: 400,
      );

      final txns = await dao.getTransactions();
      final split = txns.singleWhere((t) => TransactionType.fromStorage(t.type) == TransactionType.split);

      // The split is no longer the latest transaction of the holding:
      // reversing it would rescale the later buy's numbers too.
      final remove = await service.remove(split.id);
      expect(remove.ok, isFalse);
      expect(remove.message, contains('更晚的交易'));

      // In strict order the reversal works and restores the scale.
      final latestBuy = txns.singleWhere((t) => TransactionType.fromStorage(t.type) == TransactionType.buy && t.quantity == 50);
      final firstBuy = txns.singleWhere((t) => TransactionType.fromStorage(t.type) == TransactionType.buy && t.quantity == 100);
      expect((await service.remove(latestBuy.id)).ok, isTrue);
      expect((await service.remove(split.id)).ok, isTrue);
      expect((await service.remove(firstBuy.id)).ok, isTrue);
      final holding = (await dao.getHolding(stockId))!;
      expect(holding.quantity, closeTo(100, 1e-9));
      expect(holding.costPrice, closeTo(10, 1e-9));
    });
  });

  group('target allocation', () {
    test('unknown keys are ignored, not folded into 债券 (M10)', () {
      final plan = parseTargetAllocation('{"equity":40,"weird_key":7}');
      expect(plan[AssetCategory.bond], 25); // untouched default
      expect(plan.values.contains(7), isFalse);
    });

    test('normalizeTargetAllocation caps the total at 100 with one decimal (M11)', () {
      final normalized = normalizeTargetAllocation({
        AssetCategory.equity: 27.5,
        AssetCategory.bond: 52.5,
        AssetCategory.cash: 10,
        AssetCategory.gold: 5,
        AssetCategory.commodity: 5,
      });
      // 27.5 + 52.5 = 100 already; rounding to one decimal must not push it
      // to 101 (the old roundToDouble encode could persist 28 + 53 + ...).
      final total = normalized.values.fold(0.0, (a, b) => a + b);
      expect(total, lessThanOrEqualTo(100.0));
      expect(normalized[AssetCategory.equity], anyOf(27.5, lessThan(27.5)));

      final overflow = normalizeTargetAllocation({
        AssetCategory.equity: 60.0,
        AssetCategory.bond: 60.0,
      });
      expect(overflow.values.fold(0.0, (a, b) => a + b), lessThanOrEqualTo(100.0));
    });

    test('roundToDouble-style integer round-trip no longer inflates (M11)', () {
      const plan = {
        AssetCategory.equity: 27.5,
        AssetCategory.bond: 52.5,
        AssetCategory.cash: 10.0,
        AssetCategory.gold: 5.0,
        AssetCategory.commodity: 5.0,
      };
      final encoded = encodeTargetAllocation(plan);
      final decoded = parseTargetAllocation(encoded);
      expect(decoded[AssetCategory.equity], 27.5);
      expect(decoded[AssetCategory.bond], 52.5);
    });
  });

  test('monthly rate denominator is the asset-side base (M5)', () {
    final calc = DailyEarningsCalculator();
    final earnings = [
      DailyEarning(
        date: '2025-01-01',
        profit: 0,
        totalValue: 900,
        totalCost: 900,
        liabilities: 100,
      ),
      DailyEarning(
        date: '2025-01-02',
        profit: 100,
        totalValue: 1000,
        totalCost: 900,
        liabilities: 100,
      ),
    ];
    final month = calc.monthOf(earnings, 2025, 1);
    expect(month.total, 100);
    // Net worth base (900) would inflate the rate to ~11.1%.
    expect(month.rate, closeTo(0.1, 1e-9));
  });

  test('replay of a past window ignores later events (H4)', () {
    HoldingRow holding(DateTime t) => HoldingRow(
          id: 1,
          accountId: 1,
          name: 'H',
          assetType: 'stock',
          marketSource: 'manual',
          quantity: 0,
          costPrice: 0,
          latestPrice: 0,
          currency: 'CNY',
          archived: false,
          createdAt: t,
          updatedAt: t,
        );
    TransactionRow txn(int id, String type, double qty, double amount, DateTime when) =>
        TransactionRow(
          id: id,
          accountId: 1,
          holdingId: 1,
          type: type,
          quantity: qty,
          amount: amount,
          currency: 'CNY',
          occurredAt: when,
          costMoved: true,
          updatedAt: when,
        );

    // Sold out on 2025-12-15; a second sell happens on 2026-06-01.
    final replay = const HoldingReplay().replay(
      holding(DateTime(2025, 1, 1)),
      [
        txn(1, 'sell', 10, 1000, DateTime(2025, 12, 15, 10)),
        txn(2, 'sell', 10, 1000, DateTime(2026, 6, 1, 10)),
      ],
      from: DateTime(2025, 1, 1),
      to: DateTime(2025, 12, 31),
    );

    // The 2026 sale must NOT leak into the 2025 window's final day.
    expect(replay['2025-12-31']?.$1, closeTo(10, 1e-9));
    expect(replay['2025-12-15']?.$1, closeTo(10, 1e-9));
  });

  test('backup import writes effective ids on a used database (C2)', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = AssetDao(db);
    // Raise the real AUTOINCREMENT high-water mark with throwaway rows.
    final acc = await dao.createAccount(AccountsCompanion.insert(name: '旧', type: 'general'));
    await dao.createHolding(HoldingsCompanion.insert(
      id: const Value(30),
      accountId: acc,
      name: '旧持仓',
      assetType: 'savings',
    ));
    await dao.deleteHolding(30);
    await dao.deleteAccount(acc);

    // v1-style backup: holdings carry no ids, transactions carry none.
    final backup = jsonEncode({
      'app': 'asset_tracker',
      'version': 1,
      'accounts': [
        {
          'id': 1,
          'name': 'A',
          'type': 'general',
          'createdAt': '2026-01-01T00:00:00',
          'updatedAt': '2026-01-01T00:00:00',
        },
      ],
      'holdings': [
        {
          'accountId': 1,
          'name': 'H1',
          'assetType': 'savings',
          'quantity': 100,
          'costPrice': 100,
          'latestPrice': 1,
          'currency': 'CNY',
          'createdAt': '2026-01-01T00:00:00',
          'updatedAt': '2026-01-01T00:00:00',
        },
        {
          'accountId': 1,
          'name': 'H2',
          'assetType': 'savings',
          'quantity': 200,
          'costPrice': 200,
          'latestPrice': 1,
          'currency': 'CNY',
          'createdAt': '2026-01-01T00:00:00',
          'updatedAt': '2026-01-01T00:00:00',
        },
      ],
      'transactions': [],
      'snapshots': [],
      'alertRules': [],
    });

    final result = await BackupService(dao).importJson(backup);
    expect(result.ok, isTrue);
    final holdings = await dao.getHoldings();
    // The validation model (ids 1..2) and the actual rows must agree — the
    // raised AUTOINCREMENT sequence (31+) must not leak into the import.
    expect(holdings.map((h) => h.id).toList(), [1, 2]);
    await db.close();
  });
}
