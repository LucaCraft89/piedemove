/// Calls from the Android side on `piedemove/app` (MainActivity): one
/// method handler for the whole app, dispatching by method name, so the
/// trip notification's buttons and the widget's refresh do not replace each
/// other's handler.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _app = MethodChannel('piedemove/app');
final _handlers = <String, void Function(Object? arguments)>{};
var _installed = false;

/// Runs [handler] whenever Android calls [method]; a later registration for
/// the same method replaces the earlier one.
void onNativeCall(String method, void Function(Object? arguments) handler) {
  _handlers[method] = handler;
  if (_installed) return;
  try {
    _app.setMethodCallHandler((call) async {
      _handlers[call.method]?.call(call.arguments);
      return null;
    });
    _installed = true;
  } catch (e) {
    debugPrint('pm: native calls unavailable: $e');
  }
}
