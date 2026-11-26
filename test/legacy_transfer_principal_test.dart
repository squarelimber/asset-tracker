import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/history_sync.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/cash_flow_adjustments.dart';
import 'package:asset_tracker/domain/earnings_breakdown.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/domain/legacy_transfer_principal.dart';
import 'package:asset_tracker/domain/risk_metrics.dart';
import 'package:asset_tracker/domain/risk_snapshot_validation.dart';
import 'package:asset_tracker/services/history_backfill_service.dart';
import 'package:asset_tracker/services/snapshot_service.dart';

DayHoldingValue _value(
  int id,
  double cost, {
  AssetType type = AssetType.cash,
  double? value,
}) => DayHoldingValue(
  holdingId: id,
  name: '产品$id',
  type: type,
  value: value ?? cost,
  cost: type == AssetType.liability ? 0 : cost,
  liability: type == AssetType.liability,
);

SnapshotRow _snapshot(int day, List<DayHoldingValue> values) {
  final debt = values
      .where((v) => v.liability)
      .fold(0.0, (s, v) => s + v.value);
  return SnapshotRow(
    date: '2026-07-${day.toString().padLeft(2, '0')}',
    currency: 'CNY',
    totalValue:
        values.where((v) => !v.liability).fold(0.0, (s, v) => s + v.value) -
        debt,
    totalCost: values.fold(0.0, (s, v) => s + v.cost),
    liabilities: debt,
    holdingValues: encodeHoldingValues(values),
    createdAt: DateTime(2026, 8, 1),
  );
}

TransactionRow _flow({
  int id = 1,
  String type = 'transfer_out',
  int? holding,
  int? source = 1,
  int? target = 2,
  double amount = 60,
  double? principal,
  double? quantity,
  bool internal = false,
}) => TransactionRow(
  id: id,
  accountId: 1,
  holdingId: holding,
  cashSourceId: source,
  cashTargetId: target,
  type: type,
  amount: amount,
  quantity: quantity,
  costMovedAmount: principal,
  costMoved: true,
  internalMove: internal,
  currency: 'CNY',
  occurredAt: DateTime(2026, 7, 7, 12, 0, id),
  updatedAt: DateTime(2026, 7, 7, 12, 0, id),
);

void main() {
  test(
    'cash redemption preserves withdrawn gain and validates risk as cash',
    () {
      final before = _snapshot(6, [
        _value(1, 100, value: 120),
      ]).copyWith(profitAdjustment: const Value(0));
      final after = _snapshot(7, [_value(1, 50, value: 60)]);
      final raw = [
        _flow(
          type: 'sell',
          holding: 1,
          source: null,
          target: null,
          quantity: 60,
        ),
      ];
      final resolved = resolveLegacyTransferPrincipal([before, after], raw);
      final adjustment = cashFlowAdjustmentsBetween(
        before,
        after,
        transactions: resolved,
      );
      expect(adjustment.verified, isTrue);
      expect(adjustment.total, 10);
      final corrected = adjustment.applyTo(after);
      expect(riskSnapshotValidationIssue(before, corrected, resolved), isNull);
      final risk = estimateRiskMetrics(
        [before, corrected],
        raw,
        annualRiskFreeRate: 0.01,
        now: DateTime(2026, 8, 2),
      );
      expect(risk.sampleCount, 1);
      expect(risk.usesSnapshotPrincipal, isTrue);
      expect(corrected.realizedProfit, isNull);
      final documented = estimateRiskMetrics(
        [before, corrected],
        resolved,
        annualRiskFreeRate: 0.01,
        now: DateTime(2026, 8, 2),
      );
      expect(documented.usesSnapshotPrincipal, isFalse);
    },
  );

  test(
    'recovers debt repayment from recorded costs without changing the ledger',
    () {
      final before = _snapshot(6, [
        _value(1, 100, value: 120),
        _value(2, 100, type: AssetType.liability),
      ]);
      final after = _snapshot(7, [
        _value(1, 50, value: 60),
        _value(2, 40, type: AssetType.liability),
      ]);
      final row = _flow();
      final resolved = resolveLegacyTransferPrincipal(
        [before, after],
        [row],
      ).single;
      expect(resolved.costMovedAmount, 50);
      expect(row.costMovedAmount, isNull);
      expect(resolved.updatedAt, row.updatedAt);
      expect(resolved.amount, row.amount);
      final adjusted = cashFlowAdjustmentsBetween(
        before,
        after,
        transactions: [resolved],
      );
      expect(adjusted.verified, isTrue);
      expect(adjusted.total, 10);
    },
  );

  test(
    'expense principal can exceed the paid amount for a losing cash product',
    () {
      final before = _snapshot(6, [_value(1, 140, value: 120)]);
      final after = _snapshot(7, [_value(1, 70, value: 60)]);
      final resolved = resolveLegacyTransferPrincipal(
        [before, after],
        [_flow(type: 'expense', source: null, target: 1)],
      );
      expect(resolved.single.costMovedAmount, 70);
      expect(
        cashFlowAdjustmentsBetween(before, after, transactions: resolved).total,
        -10,
      );
    },
  );

  test('solves a cash-funded buy and a later transfer together', () {
    final snapshots = [
      _snapshot(6, [
        _value(1, 200),
        _value(2, 100, type: AssetType.etf),
        _value(3, 0),
      ]),
      _snapshot(7, [
        _value(1, 100),
        _value(2, 150, type: AssetType.etf),
        _value(3, 50),
      ]),
    ];
    final rows = [
      _flow(type: 'buy', holding: 2, target: null, amount: 60, quantity: 5),
      _flow(id: 2, target: 3),
    ];
    final resolved = resolveLegacyTransferPrincipal(snapshots, rows);
    expect(resolved.map((r) => r.costMovedAmount), [50, 50]);
    expect(productsFromSnapshots(snapshots, transactions: rows), isNotEmpty);
    expect(
      earningsBreakdownOf(snapshots, '2026-07-07', transactions: rows).verified,
      isTrue,
    );
  });

  test('uses equal share unit cost to separate two partial sales', () {
    final snapshots = [
      _snapshot(6, [
        _value(1, 1000, type: AssetType.etf),
        _value(2, 100),
        _value(3, 0),
      ]),
      _snapshot(7, [
        _value(1, 700, type: AssetType.etf),
        _value(2, 200),
        _value(3, 200),
      ]),
    ];
    final resolved = resolveLegacyTransferPrincipal(snapshots, [
      _flow(type: 'sell', holding: 1, source: null, quantity: 1, amount: 110),
      _flow(
        id: 2,
        type: 'sell',
        holding: 1,
        source: null,
        quantity: 2,
        amount: 220,
      ),
      _flow(id: 3, source: 2, target: 3, amount: 200),
    ]);
    expect(resolved.map((r) => r.costMovedAmount), [100, 200, 200]);
  });

  test('ambiguous repeated transfers remain unresolved', () {
    final rows = [_flow(), _flow(id: 2)];
    final resolved = resolveLegacyTransferPrincipal([
      _snapshot(6, [_value(1, 1000), _value(2, 0)]),
      _snapshot(7, [_value(1, 700), _value(2, 300)]),
    ], rows);
    expect(identical(resolved, rows), isTrue);
    expect(resolved.every((r) => r.costMovedAmount == null), isTrue);
  });

  test('unexplained changes on the same funds prevent recovery', () {
    final rows = [_flow()];
    final resolved = resolveLegacyTransferPrincipal([
      _snapshot(6, [_value(1, 100), _value(2, 0)]),
      _snapshot(7, [_value(1, 50), _value(2, 60)]),
    ], rows);
    expect(resolved, rows);
  });

  test(
    'an unrelated new position does not block a uniquely reconciled flow',
    () {
      final resolved = resolveLegacyTransferPrincipal(
        [
          _snapshot(6, [_value(1, 100), _value(2, 0)]),
          _snapshot(7, [
            _value(1, 50),
            _value(2, 50),
            _value(3, 200, type: AssetType.etf),
          ]),
        ],
        [_flow()],
      );
      expect(resolved.single.costMovedAmount, 50);
    },
  );

  for (final condition in [
    'gap',
    'stale',
    'foreign',
    'malformed',
    'type change',
    'negative',
  ]) {
    test('does not guess with $condition evidence', () {
      var before = _snapshot(condition == 'gap' ? 5 : 6, [
        _value(1, 100),
        _value(2, 0),
      ]);
      var after = _snapshot(7, [_value(1, 50), _value(2, 50)]);
      var row = _flow();
      if (condition == 'stale') {
        row = row.copyWith(updatedAt: DateTime(2026, 8, 2));
      }
      if (condition == 'foreign') row = row.copyWith(currency: 'USD');
      if (condition == 'malformed') {
        after = after.copyWith(holdingValues: const Value('invalid'));
      }
      if (condition == 'type change') {
        before = _snapshot(6, [
          _value(1, 100, type: AssetType.etf),
          _value(2, 0),
        ]);
      }
      if (condition == 'negative') {
        before = _snapshot(6, [_value(1, 0), _value(2, 100)]);
        after = _snapshot(7, [_value(1, 50), _value(2, 50)]);
      }
      expect(
        resolveLegacyTransferPrincipal(
          [before, after],
          [row],
        ).single.costMovedAmount,
        isNull,
      );
    });
  }

  test('keeps documented fields even when the snapshots disagree', () {
    final row = _flow(principal: 40);
    expect(
      resolveLegacyTransferPrincipal(
        [
          _snapshot(6, [_value(1, 100), _value(2, 0)]),
          _snapshot(7, [_value(1, 50), _value(2, 50)]),
        ],
        [row],
      ).single,
      row,
    );
  });

  test('recovers external share-sale principal in its own field', () {
    final row = _flow(
      type: 'sell',
      holding: 1,
      source: null,
      target: null,
      quantity: 1,
    );
    final resolved = resolveLegacyTransferPrincipal(
      [
        _snapshot(6, [_value(1, 100, type: AssetType.etf)]),
        _snapshot(7, [_value(1, 50, type: AssetType.etf)]),
      ],
      [row],
    ).single;
    expect(resolved.externalSellPrincipal, 50);
    expect(resolved.costMovedAmount, isNull);
  });

  test(
    'a uniquely linked redemption preserves equal principal on both legs',
    () {
      final rows = [
        _flow(
          type: 'sell',
          holding: 1,
          source: null,
          target: null,
          internal: true,
          quantity: 1,
        ),
        _flow(
          id: 2,
          type: 'buy',
          holding: 2,
          source: null,
          target: null,
          internal: true,
          quantity: 1,
        ).copyWith(occurredAt: DateTime(2026, 7, 7, 12, 0, 1)),
      ];
      final resolved = resolveLegacyTransferPrincipal([
        _snapshot(6, [
          _value(1, 100, type: AssetType.etf),
          _value(2, 0, type: AssetType.etf),
        ]),
        _snapshot(7, [
          _value(1, 50, type: AssetType.etf),
          _value(2, 50, type: AssetType.etf),
        ]),
      ], rows);
      expect(resolved.map((r) => r.costMovedAmount), [50, 50]);
    },
  );

  test(
    'full rebuild uses compatibility principal and keeps original transactions',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = AssetDao(db);
      final account = await dao.createAccount(
        AccountsCompanion.insert(name: '测试账户', type: 'general'),
      );
      final cash = await dao.createHolding(
        HoldingsCompanion.insert(
          accountId: account,
          name: '现金',
          assetType: 'cash',
          quantity: const Value(60),
          costPrice: const Value(50),
          costRecorded: const Value(true),
          purchaseDate: Value(DateTime(2026, 7, 6)),
        ),
      );
      final debt = await dao.createHolding(
        HoldingsCompanion.insert(
          accountId: account,
          name: '负债',
          assetType: 'liability',
          quantity: const Value(40),
          purchaseDate: Value(DateTime(2026, 7, 6)),
        ),
      );
      await dao.createTransaction(
        _flow(source: cash, target: debt).toCompanion(true),
      );
      for (final s in [
        _snapshot(6, [
          _value(cash, 100, value: 120),
          _value(debt, 100, type: AssetType.liability),
        ]),
        _snapshot(7, [
          _value(cash, 50, value: 60),
          _value(debt, 40, type: AssetType.liability),
        ]),
      ]) {
        await dao.upsertSnapshot(s.toCompanion(true));
      }
      final raw = await dao.getTransactions();
      await dao.setSetting(historySyncDirtyKey, historyDirtySet);
      await dao.setSetting(historyFullRebuildKey, '1');
      final result = await HistoryBackfillService(
        dao,
        sources: {},
      ).backfill(forceRebuild: true, now: DateTime(2026, 8, 2));
      expect(result.ok, isTrue, reason: result.message);
      expect(
        (await dao.getSnapshot('2026-07-07', 'CNY'))!.profitAdjustment,
        10,
      );
      expect(await dao.getTransactions(), raw);
      expect(await dao.getSetting(historyFullRebuildKey), '0');
      // Retrying the rebuild and forced daily write must not double the gain.
      final again = await HistoryBackfillService(
        dao,
        sources: {},
      ).backfill(forceRebuild: true, now: DateTime(2026, 8, 2));
      expect(again.ok, isTrue, reason: again.message);
      await SnapshotService(
        dao,
        clock: () => DateTime(2026, 8, 2, 18),
      ).ensureTodaySnapshot(force: true);
      expect(
        (await dao.getSnapshot('2026-08-02', 'CNY'))!.profitAdjustment,
        10,
      );
      expect(await dao.getTransactions(), raw);
    },
  );
}
