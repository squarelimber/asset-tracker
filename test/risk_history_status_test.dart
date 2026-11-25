import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_valuation.dart';
import 'package:asset_tracker/domain/risk_history_status.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

final _rebuiltAt = DateTime(2026, 4, 1, 16);
final _now = DateTime(2026, 4, 2);

List<SnapshotRow> _history({int days = 35}) => [
  for (var day = 0; day < days; day++)
    SnapshotRow(
      date: todayKey(DateTime(2025, 1, 1).add(Duration(days: day))),
      currency: 'CNY',
      totalValue: 1000 + day.toDouble(),
      totalCost: 1000,
      liabilities: 0,
      profitAdjustment: 0,
      holdingValues: encodeHoldingValues([
        DayHoldingValue(
          holdingId: 1,
          name: '现金',
          type: AssetType.cash,
          value: 1000 + day.toDouble(),
          cost: 1000,
          liability: false,
        ),
      ]),
      createdAt: _rebuiltAt,
    ),
];

HoldingRow _holding(DateTime updatedAt) => HoldingRow(
  id: 1,
  accountId: 1,
  name: '现金',
  assetType: AssetType.cash.storageName,
  marketSource: 'manual',
  quantity: 1034,
  costPrice: 1000,
  costRecorded: true,
  latestPrice: 1,
  currency: 'CNY',
  archived: false,
  createdAt: DateTime(2025),
  updatedAt: updatedAt,
);

bool _covers(
  List<SnapshotRow> history, {
  List<HoldingRow> holdings = const [],
  List<TransactionRow> transactions = const [],
  List<SyncTombstoneRow> tombstones = const [],
}) => riskHistoryCoversLedger(
  history,
  holdings,
  transactions,
  tombstones,
  now: _now,
);

void main() {
  test(
    'complete new snapshots cover a ledger changed before their rebuild',
    () {
      expect(_covers(_history(), holdings: [_holding(_rebuiltAt)]), isTrue);
    },
  );

  test(
    'legacy, incomplete and invalid-date snapshots cannot bypass pending history',
    () {
      final history = _history();
      for (final invalid in [
        history.last.copyWith(profitAdjustment: const Value(null)),
        history.last.copyWith(holdingValues: const Value(null)),
        history.last.copyWith(totalCost: 1010),
        history.last.copyWith(date: '2025-02-30'),
      ]) {
        expect(
          _covers([...history.take(history.length - 1), invalid]),
          isFalse,
        );
      }
      expect(_covers([]), isFalse);
      expect(_covers([history.first]), isFalse);
    },
  );

  test('holding updates newer than the rebuild keep old history blocked', () {
    final changedAt = _rebuiltAt.add(const Duration(seconds: 1));
    expect(_covers(_history(), holdings: [_holding(changedAt)]), isFalse);
    expect(
      _covers(
        [
          for (final snapshot in _history())
            snapshot.copyWith(createdAt: changedAt),
        ],
        holdings: [_holding(changedAt)],
      ),
      isTrue,
    );
  });

  test(
    'moved transactions use ledger edit time independently of their new date',
    () {
      final changedAt = _rebuiltAt.add(const Duration(seconds: 1));
      final transaction = TransactionRow(
        id: 1,
        accountId: 1,
        type: 'income',
        amount: 100,
        currency: 'CNY',
        occurredAt: DateTime(2026, 5),
        costMoved: true,
        internalMove: false,
        updatedAt: _rebuiltAt.subtract(const Duration(days: 1)),
        ledgerUpdatedAt: changedAt,
      );
      expect(_covers(_history(), transactions: [transaction]), isFalse);
      expect(
        _covers(
          [
            for (final snapshot in _history())
              snapshot.copyWith(createdAt: changedAt),
          ],
          transactions: [transaction],
        ),
        isTrue,
      );
      final restored = transaction.copyWith(
        updatedAt: changedAt.add(const Duration(days: 1)),
        ledgerUpdatedAt: Value(_rebuiltAt),
      );
      expect(_covers(_history(), transactions: [restored]), isTrue);
    },
  );

  test(
    'source deletions block stale snapshots while unrelated tombstones do not',
    () {
      final deletedAt = _rebuiltAt.add(const Duration(seconds: 1));
      for (final table in ['holdings', 'transactions', 'accounts']) {
        final tombstone = SyncTombstoneRow(
          table: table,
          rowKey: '1',
          deletedAt: deletedAt,
        );
        expect(_covers(_history(), tombstones: [tombstone]), isFalse);
        expect(
          _covers(
            [
              for (final snapshot in _history())
                snapshot.copyWith(createdAt: deletedAt),
            ],
            tombstones: [tombstone],
          ),
          isTrue,
        );
      }
      expect(
        _covers(
          _history(),
          tombstones: [
            SyncTombstoneRow(
              table: 'snapshots',
              rowKey: 'old|CNY',
              deletedAt: deletedAt,
            ),
            SyncTombstoneRow(
              table: 'alert_rules',
              rowKey: '1',
              deletedAt: deletedAt,
            ),
          ],
        ),
        isTrue,
      );
    },
  );

  test('only the last 366 completed CNY observations gate the risk window', () {
    final history = _history(days: 370);
    expect(
      _covers([
        for (var i = 0; i < history.length; i++)
          i < 4
              ? history[i].copyWith(profitAdjustment: const Value(null))
              : history[i],
        history.last.copyWith(
          date: todayKey(_now),
          holdingValues: const Value(null),
        ),
        history.last.copyWith(
          currency: 'USD',
          holdingValues: const Value(null),
        ),
      ]),
      isTrue,
    );
    expect(
      _covers([
        for (var i = 0; i < history.length; i++)
          i == 4
              ? history[i].copyWith(profitAdjustment: const Value(null))
              : history[i],
      ]),
      isFalse,
    );
  });
}
