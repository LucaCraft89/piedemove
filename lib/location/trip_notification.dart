/// The live trip's notification (native side in `MainActivity.kt`): the
/// foreground service's own notification, rewritten with the current
/// instruction, a progress bar and buttons ("Sono salito/sceso", "Termina")
/// that work with the phone locked, and the Android 13+ permission it needs.
/// Never throws.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _app = MethodChannel('piedemove/app');

Future<void> requestNotificationPermission() => _call('requestNotifications');

/// [progress] 0..100 or null; [primary] the advance button's label or null.
Future<void> showTripNotification(String title, String text,
        {int? progress, String? primary}) =>
    _call('tripNotification', {
      'title': title,
      'text': text,
      'progress': progress ?? -1,
      'primary': primary,
    });

Future<void> cancelTripNotification() => _call('tripNotificationCancel');

/// Button taps: `advance` or `stop`. One handler, the live trip's.
void onTripNotificationAction(void Function(String action) handler) {
  try {
    _app.setMethodCallHandler((call) async {
      if (call.method == 'notificationAction' && call.arguments is String) {
        handler(call.arguments as String);
      }
      return null;
    });
  } catch (e) {
    debugPrint('pm: notification actions unavailable: $e');
  }
}

Future<void> _call(String method, [Map<String, Object?>? args]) async {
  try {
    await _app.invokeMethod<Object?>(method, args);
  } catch (e) {
    debugPrint('pm: $method: $e');
  }
}
