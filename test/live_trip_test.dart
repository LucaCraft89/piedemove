/// Live trip rules (§12), on a synthetic four-stop line. Everything here is
/// the pure half: geometry build, progress, cues, off route, poor GPS.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/routing/journey.dart';

import 'support/synthetic.dart';

// ~157 m apart along a parallel of latitude.
const _lat = 45.07;
const _lon0 = 7.660, _step = 0.002;

TransitIndex _index() => syntheticIndex(
      stops: [
        for (var i = 0; i < 4; i++) ('s$i', 'Fermata $i', _lat, _lon0 + i * _step),
      ],
      patterns: [
        ('2', RouteType.bus, ['s0', 's1', 's2', 's3'], [
          [0, 120, 240, 360],
        ]),
      ],
    );

Journey _journey() => Journey([
      const Leg(
        kind: LegKind.walk,
        fromStop: -1,
        toStop: 0,
        departure: 0,
        arrival: 60,
        walkMetres: 80,
      ),
      const Leg(
        kind: LegKind.ride,
        fromStop: 0,
        toStop: 3,
        departure: 60,
        arrival: 420,
        options: [
          RideOption(
            routeShortName: '2',
            routeType: RouteType.bus,
            pattern: 0,
            trip: 0,
            departure: 60,
            arrival: 420,
          ),
        ],
      ),
    ], DateTime(2026, 9, 19));

LiveTripState _start({double? originLat, double? originLon}) {
  final route = buildLiveRoute(
    _index(),
    null,
    _journey(),
    originLat: originLat ?? _lat,
    originLon: originLon ?? _lon0 - 0.001,
  );
  return LiveTripState(
    route: route,
    journey: _journey(),
    metresToEnd: route.legs.first.metres,
    stopsRemaining: route.legs.first.stopVertex.length,
  );
}

LiveFix _fix(
  double lat,
  double lon, {
  double accuracy = 8,
  double speed = 1.2,
  DateTime? at,
}) =>
    LiveFix(
      lat: lat,
      lon: lon,
      accuracy: accuracy,
      speed: speed,
      at: at ?? DateTime(2026, 9, 19, 9),
    );

void main() {
  test('a ride leg counts the stops left and cues once each', () {
    var s = _start();
    // Boarding: at the stop, moving like a vehicle.
    s = advanceLive(s, _fix(_lat, _lon0, speed: 6));
    expect(s.legIndex, 1);
    expect(s.stopsRemaining, 3);

    s = advanceLive(s, _fix(_lat, _lon0 + _step, speed: 6));
    expect(s.stopsRemaining, 2);
    expect(s.cue, isNull);

    s = advanceLive(s, _fix(_lat, _lon0 + 2 * _step, speed: 6));
    expect(s.stopsRemaining, 1);
    expect(s.cue, LiveCue.oneStopLeft);

    // At the alight stop: the last cue fires, then the journey is done.
    s = advanceLive(s, _fix(_lat, _lon0 + 3 * _step, speed: 6));
    expect(s.finished, isTrue);
  });

  test('walking up to the stop does not board without vehicle speed', () {
    var s = _start();
    s = advanceLive(s, _fix(_lat, _lon0, speed: 1.1));
    expect(s.legIndex, 0, reason: 'still walking');

    s = advanceLive(s, _fix(_lat, _lon0, speed: 1.1),
        vehicleLat: _lat, vehicleLon: _lon0);
    expect(s.legIndex, 1, reason: 'the matched vehicle is right there');
  });

  test('progress is monotone: a fix behind the rider does not rewind', () {
    var s = _start();
    s = advanceLive(s, _fix(_lat, _lon0, speed: 6));
    s = advanceLive(s, _fix(_lat, _lon0 + 2 * _step, speed: 6));
    final forward = s.vertex;
    s = advanceLive(s, _fix(_lat, _lon0 + _step, speed: 6));
    expect(s.vertex, forward);
  });

  test('a poor fix holds the position and says it is estimated', () {
    var s = _start();
    s = advanceLive(s, _fix(_lat, _lon0, speed: 6));
    final held = s.vertex;
    s = advanceLive(s, _fix(_lat + 0.01, _lon0, accuracy: 120, speed: 6));
    expect(s.estimated, isTrue);
    expect(s.vertex, held);

    // With a known vehicle the estimate follows it instead of freezing.
    s = advanceLive(
      s,
      _fix(_lat + 0.01, _lon0, accuracy: 120, speed: 6),
      vehicleLat: _lat,
      vehicleLon: _lon0 + 2 * _step,
    );
    expect(s.estimated, isTrue);
    expect(s.vertex, greaterThan(held));
  });

  test('off route only after 150 m for 30 s, and never recalculates', () {
    final t0 = DateTime(2026, 9, 19, 9);
    var s = _start();
    s = advanceLive(s, _fix(_lat, _lon0, speed: 6, at: t0));
    s = advanceLive(s, _fix(_lat + 0.004, _lon0 + _step, speed: 6, at: t0));
    expect(s.offRoute, isFalse, reason: 'far, but not yet for long enough');

    s = advanceLive(
      s,
      _fix(_lat + 0.004, _lon0 + _step,
          speed: 6, at: t0.add(const Duration(seconds: 31))),
    );
    expect(s.offRoute, isTrue);
    expect(s.legIndex, 1, reason: 'the journey is untouched');
  });

  test('no fix for 20 s estimates from the schedule', () {
    // The leg's times are seconds from the service day's midnight, so the
    // clock in this test runs on that day from 00:00.
    final start = DateTime(2026, 9, 19);
    final t0 = start.add(const Duration(seconds: 60));
    var s = _start();
    s = advanceLive(s, _fix(_lat, _lon0, speed: 6, at: t0));
    final before = s.vertex;
    final s2 = staleLive(
      s,
      start.add(const Duration(seconds: 300)),
      serviceStart: start,
    );
    expect(s2.estimated, isTrue);
    expect(s2.vertex, greaterThan(before));
  });

  test('manual board and alight always work', () {
    var s = _start();
    s = nextLeg(s);
    expect(s.legIndex, 1);
    s = nextLeg(s);
    expect(s.finished, isTrue);
  });
}
