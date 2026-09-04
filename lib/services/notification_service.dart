import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Wraps flutter_local_notifications for alert notifications.
///
/// Supported platforms:
/// - Android: requests the POST_NOTIFICATIONS runtime permission (API 33+).
/// - Windows: registers the app under a fixed AppUserModelId (the plugin
///   writes the registry entries itself during [init]).
///
/// Web is intentionally left as a no-op: the web build is a public demo, the
/// plugin would replace the default service worker, and browsers only grant
/// the notification permission in response to a user gesture.
class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Android channel all alert notifications are posted to.
  static const String alertChannelId = 'alerts';

  /// Identifies this app in the Windows Action Center / toast.
  static const String _windowsAppUserModelId = 'com.squarelimber.AssetTracker';

  /// Fixed GUID for the Windows notification activation registration.
  static const String _windowsGuid = '93da9390-8f13-4044-8b5a-64485e319335';

  bool _initialized = false;
  bool _canShow = false;

  /// Whether [showAlert] will actually post a notification right now.
  bool get canShow => _initialized && _canShow;

  /// Initializes the platform plugin and (on Android) requests the
  /// POST_NOTIFICATIONS permission. Safe to call multiple times: the
  /// permission prompt is only shown while the permission is undecided.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (kIsWeb) return; // web: intentionally a no-op (see class docs)
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission();
      _canShow = granted ?? false;
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      await _plugin.initialize(
        InitializationSettings(
          windows: WindowsInitializationSettings(
            appName: 'Asset Tracker',
            appUserModelId: _windowsAppUserModelId,
            guid: _windowsGuid,
            iconPath: _windowsIconPath(),
          ),
        ),
      );
      _canShow = true;
    }
    // Other platforms (web): intentionally a no-op.
  }

  /// (Re-)checks the OS permission without re-running initialization.
  /// Used when the user re-enables notifications in settings after a
  /// previous denial: Android returns the current state without showing a
  /// prompt again.
  Future<bool> refreshPermission() async {
    if (!_initialized) return _canShow;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission();
      if (granted != null) _canShow = granted;
    }
    return _canShow;
  }

  /// Shows one alert notification. No-op when [init] has not been called or
  /// the platform/permission does not allow posting.
  Future<void> showAlert({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!canShow) return;
    const androidDetails = AndroidNotificationDetails(
      alertChannelId,
      '资产提醒',
      channelDescription: '风险预警与现金流提醒',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(
      android: androidDetails,
      windows: WindowsNotificationDetails(),
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  /// The app icon next to the Windows executable (resources/app_icon.ico),
  /// used as the toast icon. Null when the file is not present.
  static String? _windowsIconPath() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final icon = File('$exeDir${Platform.pathSeparator}resources'
          '${Platform.pathSeparator}app_icon.ico');
      return icon.existsSync() ? icon.path : null;
    } catch (_) {
      return null;
    }
  }
}

/// Single shared instance. The plugin's native side is a process-wide
/// singleton, and re-initializing it would re-trigger the Android permission
/// prompt, so every call site (startup, settings, pages) uses this one object.
final NotificationService notificationService = NotificationService();
