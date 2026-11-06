import 'dart:convert';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/target_allocation.dart';
import 'package:asset_tracker/services/alert_notification_service.dart';
import 'package:asset_tracker/services/alert_service.dart';
import 'package:asset_tracker/services/notification_service.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _Notifications extends NotificationService {
  final ids = <int>[];
  @override
  Future<void> showAlert({
    required int id,
    required String title,
    required String body,
  }) async {
    ids.add(id);
  }
}

void main() {
  late AppDatabase db;
  late AssetDao dao;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
  });
  tearDown(() => db.close());

  test(
    'one rule records each distinct holding once even with identical names',
    () async {
      final account = await dao.createAccount(
        AccountsCompanion.insert(name: 'a', type: 'general'),
      );
      for (var i = 0; i < 2; i++) {
        await dao.createHolding(
          HoldingsCompanion.insert(
            accountId: account,
            name: '同名',
            assetType: AssetType.cash.storageName,
            quantity: const Value(100),
            latestPrice: const Value(0),
          ),
        );
      }
      await dao.createAlertRule(
        AlertRulesCompanion.insert(
          name: '占比',
          type: AlertRuleType.concentration.storageName,
          params: Value(jsonEncode({'threshold': .3})),
        ),
      );
      final service = AlertService(dao);
      final now = DateTime(2026, 11, 6, 12);
      final events = await service.evaluateAll(now: now);
      expect(events, hasLength(2));
      expect(events[0].message, isNot(events[1].message));
      expect(await service.evaluateAll(now: now), isEmpty);
      expect(
        await dao.getSetting(AlertService.lastCheckedKey),
        now.toIso8601String(),
      );
    },
  );

  test(
    'allocation-following rule uses saved target, legacy rule keeps custom target',
    () async {
      final account = await dao.createAccount(
        AccountsCompanion.insert(name: 'a', type: 'general'),
      );
      await dao.createHolding(
        HoldingsCompanion.insert(
          accountId: account,
          name: '股票',
          assetType: AssetType.stock.storageName,
          quantity: const Value(1),
          latestPrice: const Value(40),
        ),
      );
      await dao.createHolding(
        HoldingsCompanion.insert(
          accountId: account,
          name: '现金',
          assetType: AssetType.cash.storageName,
          quantity: const Value(60),
          latestPrice: const Value(1),
        ),
      );
      await dao.setSetting(targetAllocationKey, jsonEncode({'equity': 40}));
      await dao.createAlertRule(
        AlertRulesCompanion.insert(
          name: '跟随',
          type: AlertRuleType.assetRatio.storageName,
          params: Value(jsonEncode({'followTarget': true, 'tolerance': .05})),
        ),
      );
      await dao.createAlertRule(
        AlertRulesCompanion.insert(
          name: '旧规则',
          type: AlertRuleType.assetRatio.storageName,
          params: Value(jsonEncode({'target': .6, 'tolerance': .05})),
        ),
      );
      final events = await AlertService(
        dao,
      ).evaluateAll(now: DateTime(2026, 11, 6));
      expect(events, hasLength(1));
      expect(events.single.message, contains('目标 60.0%'));
    },
  );

  test(
    'manual check both records and notifies, without duplicate later notification',
    () async {
      await dao.createAlertRule(
        AlertRulesCompanion.insert(
          name: '还款',
          type: AlertRuleType.cashflow.storageName,
          params: Value(jsonEncode({'dayOfMonth': 6, 'label': '还款'})),
        ),
      );
      final notifications = _Notifications();
      final service = AlertNotificationService(dao, notifications);
      final now = DateTime(2026, 11, 6, 12);
      expect(await service.runCheck(now: now), hasLength(1));
      expect(notifications.ids, hasLength(1));
      expect(await service.checkAndNotify(now: now), 0);
      expect(notifications.ids, hasLength(1));
    },
  );

  test(
    '30-day lead can reach two months ahead and coexist with today',
    () async {
      await dao.createAlertRule(
        AlertRulesCompanion.insert(
          name: '每月月初',
          type: AlertRuleType.cashflow.storageName,
          params: Value(
            jsonEncode({'dayOfMonth': 1, 'label': '月初', 'advanceDays': 30}),
          ),
        ),
      );
      final service = AlertService(dao);
      final january = await service.evaluateAll(now: DateTime(2027, 1, 30));
      expect(january, hasLength(1));
      expect(january.single.message, contains('2027-03-01'));
      expect(
        await service.evaluateAll(now: DateTime(2027, 1, 30, 18)),
        isEmpty,
      );

      final april = await service.evaluateAll(now: DateTime(2027, 4, 1));
      expect(april, hasLength(2));
      expect(
        april.map((e) => e.message),
        containsAll([contains('2027-04-01'), contains('2027-05-01')]),
      );
      expect(await service.evaluateAll(now: DateTime(2027, 4, 1, 18)), isEmpty);
    },
  );
}
