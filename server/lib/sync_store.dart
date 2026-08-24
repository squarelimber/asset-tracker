import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Dumb storage for the sync protocol: one revision, the full latest
/// snapshot and the tombstone list. All merge logic lives on the clients;
/// the server only authenticates and atomically replaces the snapshot.
class SyncStore {
  SyncStore(String path) {
    _db = sqlite3.open(path);
    _db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        rev INTEGER NOT NULL DEFAULT 0,
        snapshot TEXT NOT NULL DEFAULT '{}',
        tombstones TEXT NOT NULL DEFAULT '[]',
        updated_at TEXT NOT NULL
      );
    ''');
  }

  late final Database _db;

  /// Current revision and payload, or null when nothing was pushed yet.
  ({int rev, Map<String, dynamic> snapshot, List<dynamic> tombstones})?
      read() {
    final result =
        _db.select('SELECT rev, snapshot, tombstones FROM sync_state WHERE id = 1');
    if (result.isEmpty) return null;
    final row = result.first;
    return (
      rev: row['rev'] as int,
      snapshot: jsonDecode(row['snapshot'] as String) as Map<String, dynamic>,
      tombstones: jsonDecode(row['tombstones'] as String) as List<dynamic>,
    );
  }

  /// Atomically replaces the snapshot, bumping the revision by one.
  ///
  /// Pass [baseRev] for optimistic concurrency: when the store's current
  /// revision differs from it, nothing is written and the result carries
  /// `conflict: true` together with the current revision, so the client can
  /// re-merge against the newer state and retry.
  ({int rev, Map<String, dynamic> snapshot, List<dynamic> tombstones, bool conflict})
      write(
    Map<String, dynamic> snapshot,
    List<dynamic> tombstones, {
    int? baseRev,
  }) {
    final current = read();
    if (baseRev != null && (current?.rev ?? 0) != baseRev) {
      return (
        rev: current?.rev ?? 0,
        snapshot: snapshot,
        tombstones: tombstones,
        conflict: true,
      );
    }
    final nextRev = (current?.rev ?? 0) + 1;
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      '''
      INSERT INTO sync_state (id, rev, snapshot, tombstones, updated_at)
      VALUES (1, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        rev = excluded.rev,
        snapshot = excluded.snapshot,
        tombstones = excluded.tombstones,
        updated_at = excluded.updated_at;
      ''',
      [nextRev, jsonEncode(snapshot), jsonEncode(tombstones), now],
    );
    return (rev: nextRev, snapshot: snapshot, tombstones: tombstones, conflict: false);
  }

  void close() => _db.dispose();
}
