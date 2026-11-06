import '../data/asset_dao.dart';
import '../data/database.dart';
import 'alert_service.dart';
import 'notification_service.dart';

/// Evaluates all enabled alert rules and shows one local notification per
/// newly fired event.
///
/// Called from app startup and after market refresh — the moments when new
/// information (fresh prices, the monthly cashflow day) appears while the
/// user is not looking at the alerts page. Manual checks use [runCheck] so
/// they do not create an event that silently suppresses its notification.
class AlertNotificationService {
  AlertNotificationService(this._dao, this._notifications);

  final AssetDao _dao;
  final NotificationService _notifications;

  /// Setting key that disables local notifications ('false' = off;
  /// absent = on).
  static const String enabledKey = 'notifications_enabled';

  /// Evaluates rules even when notifications are disabled. When notifications
  /// are enabled, deliver each new event as part of the same check.
  Future<List<AlertEventRow>> runCheck({DateTime? now}) async {
    final events = await AlertService(_dao).evaluateAll(now: now);
    final enabled = await _dao.getSetting(enabledKey);
    if (enabled != 'false') {
      for (final event in events) {
        try {
          await _notifications.showAlert(
            id: event.id,
            title: event.title,
            body: event.message,
          );
        } catch (_) {
          // The event is already recorded; a platform notification failure
          // must not make a successful manual check look like a failed one.
        }
      }
    }
    return events;
  }

  /// Runs all rules and notifies for every newly fired event.
  ///
  /// Returns the number of new events (0 when notifications are disabled,
  /// nothing fired, or an error occurred). Never throws: notifications are
  /// best-effort and must not break the caller (startup, market refresh).
  Future<int> checkAndNotify({DateTime? now}) async {
    try {
      final enabled = await _dao.getSetting(enabledKey);
      if (enabled == 'false') return 0;
      final events = await runCheck(now: now);
      return events.length;
    } catch (_) {
      return 0;
    }
  }
}
