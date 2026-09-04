import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/alert_notification_service.dart';
import 'package:asset_tracker/services/notification_service.dart';

/// Records "shown" notifications without touching any platform channel.
class _RecordingNotifications extends NotificationService {
  final List<({int id, String title, String body})> shown = [];

  @override
  Future<void> showAlert({
    required int id,
    required String title,
    required String body,
  }) async {
    shown.add((id: id, title: title, body: body));
  }
}

void main() {
  late AppDatabase db;
  late AssetDao dao;
  late _RecordingNotifications notifications;
  late AlertNotificationService service;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = AssetDao(db);
    notifications = _RecordingNotifications();
    service = AlertNotificationService(dao, notifications);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> addCashflowRule({
    required int day,
    String label = '还贷',
    bool enabled = true,
  }) {
    return dao.createAlertRule(AlertRulesCompanion.insert(
      type: AlertRuleType.cashflow.storageName,
      name: '测试规则',
      params: Value(jsonEncode({'dayOfMonth': day, 'label': label})),
      enabled: Value(enabled),
    ));
  }

  test('no rules: nothing fires, no notification', () async {
    final count = await service.checkAndNotify(now: DateTime(2026, 8, 15));
    expect(count, 0);
    expect(notifications.shown, isEmpty);
  });

  test('cashflow rule on its day fires once and notifies', () async {
    await addCashflowRule(day: 15);
    final count = await service.checkAndNotify(now: DateTime(2026, 8, 15, 10));
    expect(count, 1);
    expect(notifications.shown, hasLength(1));
    expect(notifications.shown.single.title, '现金流提醒');
    expect(notifications.shown.single.body, contains('还贷'));
  });

  test('same rule does not notify twice on the same day', () async {
    await addCashflowRule(day: 15);
    expect(await service.checkAndNotify(now: DateTime(2026, 8, 15, 10)), 1);
    // Later the same day (e.g. a market refresh): deduped.
    expect(await service.checkAndNotify(now: DateTime(2026, 8, 15, 22)), 0);
    expect(notifications.shown, hasLength(1));
    // The following month: fires again with a fresh event id.
    expect(await service.checkAndNotify(now: DateTime(2026, 9, 15, 10)), 1);
    expect(notifications.shown, hasLength(2));
    expect(
      notifications.shown[1].id,
      isNot(notifications.shown[0].id),
    );
  });

  test('cashflow rule on another day does not fire', () async {
    await addCashflowRule(day: 1);
    final count = await service.checkAndNotify(now: DateTime(2026, 8, 15));
    expect(count, 0);
    expect(notifications.shown, isEmpty);
  });

  test('disabled rule is skipped', () async {
    await addCashflowRule(day: 15, enabled: false);
    final count = await service.checkAndNotify(now: DateTime(2026, 8, 15));
    expect(count, 0);
    expect(notifications.shown, isEmpty);
  });

  test('disabled via settings: rules still evaluated but no notification',
      () async {
    await addCashflowRule(day: 15);
    await dao.setSetting(AlertNotificationService.enabledKey, 'false');
    final count = await service.checkAndNotify(now: DateTime(2026, 8, 15));
    expect(count, 0);
    expect(notifications.shown, isEmpty);
  });

  test('re-enabled via settings notifies again', () async {
    await addCashflowRule(day: 15);
    await dao.setSetting(AlertNotificationService.enabledKey, 'false');
    await dao.setSetting(AlertNotificationService.enabledKey, 'true');
    final count = await service.checkAndNotify(now: DateTime(2026, 8, 15));
    expect(count, 1);
    expect(notifications.shown, hasLength(1));
  });
}
