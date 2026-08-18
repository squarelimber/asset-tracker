import 'dart:convert';

import 'sync_format.dart';

/// A tombstone entry as transmitted over the wire.
class TombstoneEntry {
  const TombstoneEntry({required this.table, required this.rowKey, required this.deletedAt});

  final String table;
  final String rowKey;
  final DateTime deletedAt;

  Map<String, dynamic> toJson() => {
        'table': table,
        'rowKey': rowKey,
        'deletedAt': deletedAt.toIso8601String(),
      };

  static TombstoneEntry? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    // drift DataClass.toJson emits DateTime as epoch milliseconds; the
    // wire format uses ISO-8601 — accept both.
    final raw = value['deletedAt'];
    final DateTime? deletedAt;
    if (raw is num) {
      deletedAt = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    } else {
      deletedAt = parseIso(raw);
    }
    if (deletedAt == null) return null;
    return TombstoneEntry(
      table: '${value['table']}',
      rowKey: '${value['rowKey']}',
      deletedAt: deletedAt,
    );
  }
}

/// Merge outcome for one table.
class MergedTable {
  const MergedTable({
    required this.rows,
    required this.deleteKeys,
    required this.conflicts,
    required this.changed,
  });

  /// Rows that must exist locally after the merge (keyed map not needed).
  final List<Map<String, dynamic>> rows;

  /// Local row keys that must be deleted (a tombstone or a newer remote
  /// deletion won).
  final List<String> deleteKeys;

  /// How many keys were edited on both sides (LWW picked the newer one).
  final int conflicts;

  /// How many rows changed locally compared to before the merge.
  final int changed;
}

/// Outcome of a full snapshot merge.
class MergeOutcome {
  const MergeOutcome({
    required this.tables,
    required this.deletedKeys,
    required this.tombstones,
    required this.conflicts,
    required this.changed,
    required this.dataChanged,
  });

  /// Merged rows per synced table.
  final Map<String, List<Map<String, dynamic>>> tables;

  /// Local row keys to delete, per table.
  final Map<String, List<String>> deletedKeys;

  /// Merged tombstone list to store locally and push to the server.
  final List<TombstoneEntry> tombstones;

  final int conflicts;
  final int changed;

  /// Whether any source-of-truth row (accounts/holdings/transactions/rules)
  /// changed locally — i.e. excluding the derived snapshots table, whose
  /// `createdAt` differences make it "change" on every merge even when the
  /// values are identical. Used to trigger a local history rebuild.
  final bool dataChanged;
}

/// Last-write-wins merge of a local snapshot against a remote one.
///
/// Rules:
/// - A tombstone beats a live row when its deletion time is newer; an older
///   tombstone is dropped (the row wins and is re-created on the remote).
/// - Otherwise the row with the newer `updatedAt` wins; a row only present
///   on one side is kept/added.
/// - When both sides modified the same row with different content, the
///   conflict counter is bumped (the newer one still wins silently).
class SyncMerger {
  const SyncMerger();

  /// Merges [local] and [remote] snapshots with the tombstone lists.
  MergeOutcome merge({
    required Map<String, dynamic> local,
    required Map<String, dynamic> remote,
    required List<TombstoneEntry> remoteTombstones,
    required List<TombstoneEntry> localTombstones,
  }) {
    final tables = <String, List<Map<String, dynamic>>>{};
    final deletedKeys = <String, List<String>>{};
    var conflicts = 0;
    var changed = 0;
    var dataChanged = false;

    for (final table in SyncTables.all) {
      final merged = mergeTable(
        table: table,
        localRows: _rowsOf(local, table),
        remoteRows: _rowsOf(remote, table),
        tombstones: remoteTombstones,
      );
      tables[table] = merged.rows;
      deletedKeys[table] = merged.deleteKeys;
      conflicts += merged.conflicts;
      changed += merged.changed;
      if (table != SyncTables.snapshots && merged.changed > 0) {
        dataChanged = true;
      }
    }

    // Tombstone union: keep the newer deletion time per key; drop a
    // tombstone when the merged row is alive and newer than the tombstone
    // (the row win is propagated by simply not carrying the tombstone).
    final tombstoneMap = <String, TombstoneEntry>{};
    for (final t in [...remoteTombstones, ...localTombstones]) {
      final key = '${t.table}:${t.rowKey}';
      final existing = tombstoneMap[key];
      if (existing == null || t.deletedAt.isAfter(existing.deletedAt)) {
        tombstoneMap[key] = t;
      }
    }
    final mergedRowsByKey = <String, Map<String, dynamic>>{};
    for (final table in SyncTables.all) {
      for (final row in tables[table]!) {
        mergedRowsByKey['$table:${syncRowKey(table, row)}'] = row;
      }
    }
    tombstoneMap.removeWhere((key, t) {
      final row = mergedRowsByKey[key];
      return row != null && _updatedAt(row).isAfter(t.deletedAt);
    });

    return MergeOutcome(
      tables: tables,
      deletedKeys: deletedKeys,
      tombstones: tombstoneMap.values.toList(),
      conflicts: conflicts,
      changed: changed,
      dataChanged: dataChanged,
    );
  }

  MergedTable mergeTable({
    required String table,
    required List<Map<String, dynamic>> localRows,
    required List<Map<String, dynamic>> remoteRows,
    required List<TombstoneEntry> tombstones,
  }) {
    final byKey = <String, Map<String, dynamic>>{
      for (final r in localRows) syncRowKey(table, r): r,
    };
    final remoteByKey = <String, Map<String, dynamic>>{
      for (final r in remoteRows) syncRowKey(table, r): r,
    };
    final tombstoneByKey = {
      for (final t in tombstones.where((t) => t.table == table))
        t.rowKey: t,
    };

    final merged = <String, Map<String, dynamic>>{};
    final deleteKeys = <String>[];
    var conflicts = 0;
    var changed = 0;

    for (final key in {...byKey.keys, ...remoteByKey.keys}) {
      final local = byKey[key];
      final remote = remoteByKey[key];
      final tombstone = tombstoneByKey[key];

      if (tombstone != null) {
        final localTs = local == null ? null : _updatedAt(local);
        final remoteTs = remote == null ? null : _updatedAt(remote);
        // The tombstone wins when no live row is newer than it.
        final tombWins =
            (localTs == null || !localTs.isAfter(tombstone.deletedAt)) &&
                (remoteTs == null || !remoteTs.isAfter(tombstone.deletedAt));
        if (tombWins) {
          if (local != null) {
            deleteKeys.add(key);
            changed++;
          }
          continue; // deleted on both sides / tombstone wins
        }
        // The live row is newer than the tombstone: keep the row and let
        // the tombstone be dropped by the caller.
        final winner = _newerOf(local, remote);
        if (winner != null) {
          merged[key] = winner;
          if (remote != null && !_same(local, remote)) conflicts++;
          if (local == null || !_same(local, winner)) changed++;
        }
        continue;
      }

      if (local == null) {
        merged[key] = remote!;
        changed++;
        continue;
      }
      if (remote == null) {
        merged[key] = local;
        continue;
      }
      if (_same(local, remote)) {
        merged[key] = local;
        continue;
      }
      conflicts++;
      final winner = _newerOf(local, remote)!;
      merged[key] = winner;
      if (!_same(local, winner)) changed++;
    }

    return MergedTable(
      rows: merged.values.toList(),
      deleteKeys: deleteKeys,
      conflicts: conflicts,
      changed: changed,
    );
  }

  static DateTime _updatedAt(Map<String, dynamic> row) {
    final v = parseIso(row['updatedAt']);
    if (v != null && v.year >= 2000) return v;
    // Rows inserted without an explicit updatedAt (migration fallback,
    // legacy writes) carry the epoch default — fall back to createdAt so
    // last-write-wins still behaves sensibly.
    final created = parseIso(row['createdAt']);
    if (created != null) return created;
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  static Map<String, dynamic>? _newerOf(
    Map<String, dynamic>? a,
    Map<String, dynamic>? b,
  ) {
    if (a == null) return b;
    if (b == null) return a;
    final at = _updatedAt(a);
    final bt = _updatedAt(b);
    return at.isAfter(bt) ? a : (bt.isAfter(at) ? b : a);
  }

  static bool _same(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (a == null || b == null) return a == b;
    return jsonEncode(a) == jsonEncode(b);
  }

  static List<Map<String, dynamic>> _rowsOf(Map<String, dynamic> snapshot, String table) {
    final v = snapshot[table];
    if (v is! List) return const [];
    return v.whereType<Map<String, dynamic>>().toList();
  }
}
