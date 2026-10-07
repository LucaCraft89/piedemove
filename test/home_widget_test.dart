// The home-screen widget's data: departures with their clock times.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/app/home_widget.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/routing/departures.dart';

void main() {
  final day = DateTime(2026, 10, 7);
  Departure dep(String line, int secs, {int? delay}) => Departure(
        stop: 0,
        pattern: 0,
        trip: 0,
        routeShortName: line,
        routeType: RouteType.bus,
        headsign: 'PESCHIERA',
        scheduled: secs,
        delaySeconds: delay,
        date: day,
      );

  test('stop, times (with the delay) and live flags; capped', () {
    final now = DateTime(2026, 10, 7, 13);
    final j = jsonDecode(widgetPayload('BARDONECCHIA', [
      dep('2', 13 * 3600 + 13 * 60, delay: 120),
      dep('22', 13 * 3600 + 20 * 60),
      for (var i = 0; i < 20; i++) dep('2', 14 * 3600 + i * 600),
    ], now)) as Map<String, dynamic>;
    expect(j['stop'], 'BARDONECCHIA');
    expect(j['at'], now.millisecondsSinceEpoch);
    final deps = j['deps'] as List<dynamic>;
    expect(deps, hasLength(widgetDepartures));
    expect(deps.first['l'], '2');
    expect(deps.first['t'], DateTime(2026, 10, 7, 13, 15).millisecondsSinceEpoch);
    expect(deps.first['live'], isTrue);
    expect(deps[1]['live'], isFalse);
  });

  test('no favourite: no stop, no departures', () {
    final j = jsonDecode(widgetPayload(null, const [], DateTime(2026))) as Map;
    expect(j['stop'], isNull);
    expect(j['deps'], isEmpty);
  });
}
