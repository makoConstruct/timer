import 'package:flutter/services.dart';

/// Native notification bridge replacing awesome_notifications. Covers exactly
/// what this app uses: a channel, the timer-completion notification, cancelAll,
/// and a listener for when the user dismisses/acts on a notification.
///
/// The method handler is set per isolate; the native side (see
/// PlatformNotificationPlugin) pushes 'notificationEvent' to every live engine,
/// so whichever isolate(s) are alive run their dismiss handling.
class PlatformNotifications {
  static const MethodChannel _channel = MethodChannel('platform_notifications');

  /// Notification importance matching the old NotificationImportance.High.
  static const int importanceHigh = 4;

  static Future<void> ensureChannel({
    required String channelKey,
    required String channelName,
    required String channelDescription,
    int importance = importanceHigh,
  }) async {
    try {
      await _channel.invokeMethod('ensureChannel', {
        'channelKey': channelKey,
        'channelName': channelName,
        'channelDescription': channelDescription,
        'importance': importance,
      });
    } on PlatformException catch (e) {
      print('ensureChannel failed: ${e.message}');
    } on MissingPluginException {
      // non-Android (e.g. linux test target) — notifications are a no-op there
    }
  }

  static Future<void> showCompletion({
    required int id,
    required String channelKey,
    required String title,
    required String body,
  }) async {
    try {
      await _channel.invokeMethod('showCompletion', {
        'id': id,
        'channelKey': channelKey,
        'title': title,
        'body': body,
      });
    } on PlatformException catch (e) {
      print('showCompletion failed: ${e.message}');
    } on MissingPluginException {
      // non-Android — no-op
    }
  }

  static Future<void> cancelAll() async {
    try {
      await _channel.invokeMethod('cancelAll');
    } on PlatformException catch (e) {
      print('cancelAll failed: ${e.message}');
    } on MissingPluginException {
      // non-Android — no-op
    }
  }

  /// Registers [onEvent] to run when the user dismisses or taps an action on a
  /// notification (both mean "dismiss the alarm"). Call once per isolate.
  static void setActionListener(void Function() onEvent) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'notificationEvent') {
        onEvent();
      }
      return null;
    });
  }
}
