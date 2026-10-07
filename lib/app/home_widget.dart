/// The home-screen widget (native side: `NextDeparturesWidget.kt`): the next
/// departures at the first favourite stop, and Casa/Lavoro buttons. The app
/// writes the departures with their clock times whenever it is open; the
/// widget shows the ones still to come, so it stays right (on the timetable)
/// for hours without the app. Its buttons open the app on that trip.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:piedemove/routing/departures.dart';

const _app = MethodChannel('piedemove/app');

/// Departures written for the widget (it shows the next three still ahead).
const widgetDepartures = 12;

/// The JSON the widget reads: stop name, when written, departures with
/// their epoch time and whether that time is live.
String widgetPayload(String? stopName, List<Departure> departures, DateTime now) =>
    jsonEncode({
      'stop': stopName,
      'at': now.millisecondsSinceEpoch,
      'deps': [
        for (final d in departures.take(widgetDepartures))
          {
            'l': d.routeShortName,
            'h': d.headsign,
            't': d.time.millisecondsSinceEpoch,
            'live': d.live,
          },
      ],
    });

/// Hands the payload to the widget; a no-op when only its time changed,
/// unless [force] (the widget asked for a refresh).
String? _last;
final _at = RegExp(r'"at":\d+');
Future<void> publishWidget(String payload, {bool force = false}) async {
  final key = payload.replaceFirst(_at, '');
  if (!force && key == _last) return;
  _last = key;
  try {
    await _app.invokeMethod<Object?>('widget', {'json': payload});
  } catch (e) {
    debugPrint('pm: widget: $e');
  }
}

/// A Casa/Lavoro tap on the widget that opened the app (`home` / `work`),
/// taken once.
Future<String?> takeWidgetAction() async {
  try {
    return await _app.invokeMethod<String>('takeWidgetAction');
  } catch (_) {
    return null;
  }
}
