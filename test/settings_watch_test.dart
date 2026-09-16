import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';

/// Guards the settings-watch contract that a self-reinforcing provider loop
/// broke on 2026-09-16.
///
/// Drift emits on **every** write to the settings table, including writes to
/// unrelated keys, and Riverpod re-executes a dependent provider for every
/// emission — even when the value is identical. So a provider that watches one
/// flag and also writes *another* setting re-triggers itself forever unless
/// [AssetDao.watchSetting] dedupes. That is precisely what the backfill did
/// once it started recording its last-run anchor: the settings page flooded
/// "已回填 1 天历史净值" snackbars and the earnings calendar reloaded endlessly.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late AssetDao dao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> settle() => pumpEventQueue(times: 40);

  test('does not emit when a different key is written', () async {
    final events = <String?>[];
    final sub = dao.watchSetting('history_sync_dirty').listen(events.add);
    await settle();

    await dao.setSetting('backfill_last_run', '2026-09-16');
    await settle();

    expect(events, [null], reason: '写别的 key 不该惊动本 key 的观察者');
    await sub.cancel();
  });

  test('does not emit when it is rewritten with the same value', () async {
    await dao.setSetting('history_sync_dirty', 'clear');
    final events = <String?>[];
    final sub = dao.watchSetting('history_sync_dirty').listen(events.add);
    await settle();

    await dao.setSetting('history_sync_dirty', 'clear');
    await settle();

    expect(events, ['clear']);
    await sub.cancel();
  });

  test('emits when its own value actually changes', () async {
    await dao.setSetting('history_sync_dirty', 'clear');
    final events = <String?>[];
    final sub = dao.watchSetting('history_sync_dirty').listen(events.add);
    await settle();

    await dao.setSetting('history_sync_dirty', 'set');
    await settle();

    expect(events, ['clear', 'set']);
    await sub.cancel();
  });

  test('a provider watching a flag may write another setting without '
      're-running itself', () async {
    // Mirrors historySyncProvider: it watches the dirty flag and calls the
    // backfill, which records its own anchor in the same settings table.
    final container = ProviderContainer();
    var runs = 0;
    final flag = StreamProvider<String?>(
      (ref) => dao.watchSetting('history_sync_dirty'),
    );
    final dependent = FutureProvider<void>((ref) async {
      ref.watch(flag);
      runs++;
      await dao.setSetting('backfill_last_run', '2026-09-16');
    });
    container.listen(dependent, (_, _) {});
    await settle();

    // Two runs so far: the stream starts in the loading state and then
    // delivers its first value. What must not happen is a third one.
    final baseline = runs;

    // A write to an unrelated key must not reach the flag's observers.
    await dao.setSetting('backfill_last_run', '2026-09-17');
    await settle();
    expect(runs, baseline, reason: '写别的 key 不得重跑');

    // A real flip of the watched flag runs exactly once more, and the write
    // the run itself performs must not feed back into another run.
    await dao.setSetting('history_sync_dirty', 'set');
    await settle();
    expect(runs, baseline + 1, reason: '标志真正变化才该再跑，且自身写入不得再触发自己');

    container.dispose();
  });
}
