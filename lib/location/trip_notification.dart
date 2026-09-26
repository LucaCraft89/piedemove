/// The live trip's notification (native side in `MainActivity.kt`): the
/// foreground service's own notification, rewritten with the current
/// instruction, and the Android 13+ permission it needs. Never throws.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _app = MethodChannel('piedemove/app');

Future<void> requestNotificationPermission() => _call('requestNotifications');

Future<void> showTripNotification(String title, String text) =>
    _call('tripNotification', {'title': title, 'text': text});

Future<void> cancelTripNotification() => _call('tripNotificationCancel');

Future<void> _call(String method, [Map<String, Object?>? args]) async {
  try {
    await _app.invokeMethod<Object?>(method, args);
  } catch (e) {
    debugPrint('pm: $method: $e');
  }
}
