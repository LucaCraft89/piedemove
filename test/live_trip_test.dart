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
  group('audit fixes', () {
    LiveTripState riding() =>
        advanceLive(_start(), _fix(_lat, _lon0, speed: 6)); // boarded

    test('arriving at the alight stop vibrates "scendi ora"', () {
      var s = riding();
      s = advanceLive(s, _fix(_lat, _lon0 + 2 * _step, speed: 6));
      expect(s.cue, LiveCue.oneStopLeft);
      final seq = s.cueSeq;
      s = advanceLive(s, _fix(_lat, _lon0 + 3 * _step, speed: 6));
      expect(s.finished, isTrue);
      expect(s.cue, LiveCue.alightNow);
      expect(s.cueSeq, greaterThan(seq));
    });

    test('a poor fix with no vehicle neither moves progress nor ends the ride',
        () {
      var s = riding();
      final before = s.along;
      s = advanceLive(s, _fix(_lat, _lon0 + 3 * _step, accuracy: 120, speed: 6));
      expect(s.finished, isFalse);
      expect(s.legIndex, 1);
      expect(s.along, before);
      expect(s.estimated, isTrue);
    });

    test('projection only looks a bounded distance ahead', () {
      final leg = riding().leg;
      final end = projectAhead(leg, _lat, _lon0 + 3 * _step, 0, maxAhead: 100);
      expect(end.along, lessThan(leg.metres - 100));
      final free = projectAhead(leg, _lat, _lon0 + 3 * _step, 0,
          maxAhead: double.infinity);
      expect(free.along, closeTo(leg.metres, 1));
    });

    test('the schedule estimate follows a reported delay', () {
      final s = riding().copyWith(lastFix: DateTime(2026, 9, 19, 0, 1));
      // 00:05 is at the scheduled arrival (420 s); five minutes late, the
      // bus has only just left.
      final now = DateTime(2026, 9, 19, 0, 7);
      final onTime = staleLive(s, now, serviceStart: DateTime(2026, 9, 19));
      final late = staleLive(s, now,
          serviceStart: DateTime(2026, 9, 19), delaySeconds: 300);
      expect(onTime.stopsRemaining, 0);
      expect(late.stopsRemaining, greaterThan(0));
      expect(late.cue, isNot(LiveCue.alightNow));
    });
  });

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

  group('boarding on the road (beta 5 report: never detected)', () {
    test('wait at the stop, then the next fix is already down the line', () {
      var s = _start();
      // Standing at the stop: no speed, not boarded, but the stop is reached.
      s = advanceLive(s, _fix(_lat, _lon0 + 0.0001, speed: 0));
      expect(s.legIndex, 0);
      expect(s.reachedBoardStop, isTrue);
      // The bus left the 40 m circle between fixes; the phone reports no
      // speed. 120 m along the line: aboard, progress placed there.
      s = advanceLive(s, _fix(_lat, _lon0 + 0.0015, speed: -1));
      expect(s.legIndex, 1);
      expect(s.riding, isTrue);
      expect(s.along, greaterThan(100));
    });

    test('never at the stop: needs vehicle speed on the line', () {
      var s = _start();
      // Walking along the line past where the stop is, at walking pace.
      s = advanceLive(s, _fix(_lat, _lon0 + 0.0015, speed: 1.2));
      expect(s.legIndex, 0, reason: 'a walker on the pavement is not aboard');
      s = advanceLive(s, _fix(_lat, _lon0 + 0.0016, speed: 7));
      expect(s.legIndex, 1, reason: 'moving like a bus, on its line');
    });

    test('at the stop but off the line (another street) stays walking', () {
      var s = _start();
      s = advanceLive(s, _fix(_lat, _lon0, speed: 0));
      s = advanceLive(s, _fix(_lat + 0.003, _lon0 + 0.0015, speed: 7));
      expect(s.legIndex, 0);
    });

    test('speed from two fixes when the phone reports none', () {
      final a = _fix(_lat, _lon0, at: DateTime(2026, 9, 19, 9));
      expect(
          derivedSpeed(a, _lat, _lon0 + 0.001, DateTime(2026, 9, 19, 9, 0, 10)),
          closeTo(7.9, 0.3));
      expect(derivedSpeed(null, _lat, _lon0, DateTime(2026)), -1);
      expect(
          derivedSpeed(a, _lat, _lon0, DateTime(2026, 9, 19, 9, 1)), -1,
          reason: 'too old to mean anything');
    });
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
