import '../data/asset_dao.dart';
import 'alert_service.dart';
import 'notification_service.dart';

/// Evaluates all enabled alert rules and shows one local notification per
/// newly fired event.
///
/// Called from app startup and after market refresh — the moments when new
/// information (fresh prices, the monthly cashflow day) appears while the
/// user is not looking at the alerts page. The alerts page itself keeps its
/// own "check now" flow, which shares the same per-day dedup, so a rule can
/// never notify twice in one day.
class AlertNotificationService {
  AlertNotificationService(this._dao, this._notifications);

  final AssetDao _dao;
  final NotificationService _notifications;

  /// Setting key that disables local notifications ('false' = off;
  /// absent = on).
  static const String enabledKey = 'notifications_enabled';

  /// Runs all rules and notifies for every newly fired event.
  ///
  /// Returns the number of new events (0 when notifications are disabled,
  /// nothing fired, or an error occurred). Never throws: notifications are
  /// best-effort and must not break the caller (startup, market refresh).
  Future<int> checkAndNotify({DateTime? now}) async {
    try {
      final enabled = await _dao.getSetting(enabledKey);
      if (enabled == 'false') return 0;
      final events = await AlertService(_dao).evaluateAll(now: now);
      for (final event in events) {
        await _notifications.showAlert(
          id: event.id,
          title: event.title,
          body: event.message,
        );
      }
      return events.length;
    } catch (_) {
      return 0;
    }
  }
}
