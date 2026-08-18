import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/sync/sync_format.dart';
import 'package:asset_tracker/sync/sync_merge.dart';

Map<String, dynamic> _account(int id, {String? name, String? updatedAt}) => {
      'id': id,
      'name': name ?? 'a$id',
      'type': 'general',
      'currency': 'CNY',
      'note': null,
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': updatedAt ?? '2026-01-01T00:00:00.000Z',
    };

Map<String, dynamic> _snap(List<Map<String, dynamic>> rows) =>
    {SyncTables.accounts: rows};

void main() {
  const merger = SyncMerger();

  test('identical rows merge without conflicts', () {
    final local = _snap([_account(1, updatedAt: '2026-01-02T00:00:00.000Z')]);
    final remote = _snap([_account(1, updatedAt: '2026-01-02T00:00:00.000Z')]);
    final out = merger.merge(
      local: local,
      remote: remote,
      remoteTombstones: const [],
      localTombstones: const [],
    );
    expect(out.tables[SyncTables.accounts], hasLength(1));
    expect(out.conflicts, 0);
    expect(out.changed, 0);
  });

  test('newer row wins and counts a conflict when both edited it', () {
    final local = _snap([_account(1, name: 'local', updatedAt: '2026-01-02T00:00:00.000Z')]);
    final remote = _snap([_account(1, name: 'remote', updatedAt: '2026-01-03T00:00:00.000Z')]);
    final out = merger.merge(
      local: local,
      remote: remote,
      remoteTombstones: const [],
      localTombstones: const [],
    );
    final row = out.tables[SyncTables.accounts]!.single;
    expect(row['name'], 'remote');
    expect(out.conflicts, 1);
    expect(out.changed, 1);
  });

  test('older remote row does not overwrite a newer local one', () {
    final local = _snap([_account(1, name: 'newer', updatedAt: '2026-01-05T00:00:00.000Z')]);
    final remote = _snap([_account(1, name: 'older', updatedAt: '2026-01-04T00:00:00.000Z')]);
    final out = merger.merge(
      local: local,
      remote: remote,
      remoteTombstones: const [],
      localTombstones: const [],
    );
    expect(out.tables[SyncTables.accounts]!.single['name'], 'newer');
  });

  test('rows present on one side only are kept', () {
    final local = _snap([_account(1)]);
    final remote = _snap([_account(2, name: 'remote-only')]);
    final out = merger.merge(
      local: local,
      remote: remote,
      remoteTombstones: const [],
      localTombstones: const [],
    );
    final ids = out.tables[SyncTables.accounts]!.map((r) => r['id']).toSet();
    expect(ids, {1, 2});
  });

  test('tombstone deletes the row on the other side', () {
    final local = _snap([_account(1, updatedAt: '2026-01-02T00:00:00.000Z')]);
    final remote = _snap(const []);
    final tomb = TombstoneEntry(
      table: SyncTables.accounts,
      rowKey: '1',
      deletedAt: DateTime.utc(2026, 1, 3),
    );
    final out = merger.merge(
      local: local,
      remote: remote,
      remoteTombstones: [tomb],
      localTombstones: const [],
    );
    expect(out.tables[SyncTables.accounts], isEmpty);
    expect(out.deletedKeys[SyncTables.accounts], contains('1'));
  });

  test('row newer than the tombstone wins and drops the tombstone', () {
    final local = _snap([_account(1, updatedAt: '2026-01-05T00:00:00.000Z')]);
    final remote = _snap(const []);
    final tomb = TombstoneEntry(
      table: SyncTables.accounts,
      rowKey: '1',
      deletedAt: DateTime.utc(2026, 1, 3),
    );
    final out = merger.merge(
      local: local,
      remote: remote,
      remoteTombstones: [tomb],
      localTombstones: const [],
    );
    expect(out.tables[SyncTables.accounts], hasLength(1));
    expect(out.tombstones, isEmpty);
  });

  test('tombstone union keeps the newer deletion and drops duplicates', () {
    final tombOld = TombstoneEntry(
      table: SyncTables.accounts,
      rowKey: '1',
      deletedAt: DateTime.utc(2026, 1, 2),
    );
    final tombNew = TombstoneEntry(
      table: SyncTables.accounts,
      rowKey: '1',
      deletedAt: DateTime.utc(2026, 1, 4),
    );
    final out = merger.merge(
      local: _snap(const []),
      remote: _snap(const []),
      remoteTombstones: [tombOld],
      localTombstones: [tombNew],
    );
    expect(out.tombstones, hasLength(1));
    expect(out.tombstones.single.deletedAt, DateTime.utc(2026, 1, 4));
  });

  test('empty merge is a no-op', () {
    final out = merger.merge(
      local: const {},
      remote: const {},
      remoteTombstones: const [],
      localTombstones: const [],
    );
    expect(out.tables[SyncTables.accounts], isEmpty);
    expect(out.conflicts, 0);
    expect(out.changed, 0);
    expect(out.tombstones, isEmpty);
  });

  test('snapshot rows merge by their date|currency key', () {
    final local = {
      SyncTables.snapshots: [
        {
          'date': '2026-01-01',
          'currency': 'CNY',
          'totalValue': 100.0,
          'totalCost': 90.0,
          'liabilities': 0.0,
          'createdAt': '2026-01-01T00:00:00.000Z',
          'updatedAt': '2026-01-01T00:00:00.000Z',
        },
      ],
    };
    final remote = {
      SyncTables.snapshots: [
        {
          'date': '2026-01-02',
          'currency': 'CNY',
          'totalValue': 105.0,
          'totalCost': 90.0,
          'liabilities': 0.0,
          'createdAt': '2026-01-02T00:00:00.000Z',
          'updatedAt': '2026-01-02T00:00:00.000Z',
        },
      ],
    };
    final out = merger.merge(
      local: local,
      remote: remote,
      remoteTombstones: const [],
      localTombstones: const [],
    );
    expect(out.tables[SyncTables.snapshots], hasLength(2));
  });
}

