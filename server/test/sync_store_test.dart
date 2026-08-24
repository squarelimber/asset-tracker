import 'dart:io';

import 'package:asset_sync_server/sync_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sync_store_test');
    path = '${dir.path}/sync.sqlite';
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('empty store reads null', () {
    final store = SyncStore(path);
    expect(store.read(), isNull);
    store.close();
  });

  test('write bumps the revision and round-trips the payload', () {
    final store = SyncStore(path);
    final first = store.write({'holdings': [{'id': 1}]}, [
      {'table': 'holdings', 'rowKey': '9'},
    ]);
    expect(first.rev, 1);

    final second = store.write({'holdings': [{'id': 2}]}, const []);
    expect(second.rev, 2);

    final state = store.read();
    expect(state, isNotNull);
    expect(state!.rev, 2);
    expect((state.snapshot['holdings'] as List).single['id'], 2);
    expect(state.tombstones, isEmpty);
    store.close();
  });

  test('baseRev mismatch rejects the write and keeps the old payload', () {
    final store = SyncStore(path);
    store.write({'a': 1}, const []); // rev 1

    final stale = store.write({'a': 2}, const [], baseRev: 0);
    expect(stale.conflict, isTrue);
    expect(stale.rev, 1);

    final state = store.read();
    expect(state, isNotNull);
    expect(state!.rev, 1);
    expect(state.snapshot['a'], 1); // not overwritten

    final ok = store.write({'a': 2}, const [], baseRev: 1);
    expect(ok.conflict, isFalse);
    expect(ok.rev, 2);
    expect(store.read()!.snapshot['a'], 2);
    store.close();
  });

  test('write without baseRev always succeeds (legacy clients)', () {
    final store = SyncStore(path);
    store.write({'a': 1}, const []);
    final second = store.write({'a': 2}, const []);
    expect(second.conflict, isFalse);
    expect(second.rev, 2);
    store.close();
  });

  test('persists across reopen', () {
    final store = SyncStore(path);
    store.write({'accounts': []}, const []);
    store.close();

    final reopened = SyncStore(path);
    final state = reopened.read();
    expect(state, isNotNull);
    expect(state!.rev, 1);
    reopened.close();
  });
}
