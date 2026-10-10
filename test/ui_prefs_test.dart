import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/ui_prefs.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';

/// 「滚动卡停留时间」设置的契约测试：档位文案、持久化读取、脏值兜底。
void main() {
  test('档位文案：整秒不带小数，其余保留一位', () {
    expect(spotlightHoldLabel(5000), '5 秒');
    expect(spotlightHoldLabel(1500), '1.5 秒');
    expect(spotlightHoldLabel(defaultSpotlightHoldMs), '2.3 秒');
  });

  group('spotlightHoldMsProvider', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [daoProvider.overrideWithValue(AssetDao(db))],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('未设置时用默认值（原硬编码 2.3s，升级后观感不变）', () async {
      expect(
        await container.read(spotlightHoldMsProvider.future),
        defaultSpotlightHoldMs,
      );
    });

    test('读 settings 表里的值', () async {
      await AssetDao(db).setSetting(spotlightHoldMsKey, '5000');
      expect(await container.read(spotlightHoldMsProvider.future), 5000);
    });

    test('脏值（0 / 非数字）回退默认，否则卡片会疯狂翻转', () async {
      await AssetDao(db).setSetting(spotlightHoldMsKey, '0');
      expect(
        await container.read(spotlightHoldMsProvider.future),
        defaultSpotlightHoldMs,
      );

      await AssetDao(db).setSetting(spotlightHoldMsKey, 'abc');
      expect(
        await container.read(spotlightHoldMsProvider.future),
        defaultSpotlightHoldMs,
      );
    });
  });
}
