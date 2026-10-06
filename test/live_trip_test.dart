/// Live trip rules (§12), on a synthetic four-stop line. Everything here is
/// the pure half: geometry build, progress, cues, off route, poor GPS.
library;

import 'dart:math' as math;

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

Journey _journey({int type = RouteType.bus}) => Journey([
      const Leg(
        kind: LegKind.walk,
        fromStop: -1,
        toStop: 0,
        departure: 0,
        arrival: 60,
        walkMetres: 80,
      ),
      Leg(
        kind: LegKind.ride,
        fromStop: 0,
        toStop: 3,
        departure: 60,
        arrival: 420,
        options: [
          RideOption(
            routeShortName: '2',
            routeType: type,
            pattern: 0,
            trip: 0,
            departure: 60,
            arrival: 420,
          ),
        ],
      ),
    ], DateTime(2026, 9, 19));

LiveTripState _start(
    {double? originLat, double? originLon, int type = RouteType.bus}) {
  final route = buildLiveRoute(
    _index(),
    null,
    _journey(type: type),
    originLat: originLat ?? _lat,
    originLon: originLon ?? _lon0 - 0.001,
  );
  return LiveTripState(
    route: route,
    journey: _journey(type: type),
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

/// Seconds after 9:00 on the test day.
DateTime _t(num seconds) => DateTime(2026, 9, 19, 9)
    .add(Duration(milliseconds: (seconds * 1000).round()));

/// Degrees of longitude per metre on the test parallel.
const _lonPerMetre = 1 / 78650.0;

/// Feeds 1 Hz fixes along the test line (east), [along] metres past lon
/// [from] at each second [t0]..[t1]; returns the state and the second it
/// boarded (null when it never did).
(LiveTripState, int?) _feed(
  LiveTripState s,
  double Function(int t) along, {
  required int t0,
  required int t1,
  double from = _lon0,
  double speed = -1,
}) {
  int? boardedAt;
  for (var t = t0; t <= t1; t++) {
    final was = s.legIndex;
    s = advanceLive(
        s,
        _fix(_lat, from + along(t) * _lonPerMetre,
            speed: speed, at: _t(t)));
    if (boardedAt == null && s.legIndex > was && s.riding) boardedAt = t;
  }
  return (s, boardedAt);
}

/// A bus pulling out at [t0]: 1 m/s² up to 11 m/s (~40 km/h).
double Function(int) _busFrom(int t0, {double start = 0}) => (t) {
      final dt = math.max(0, t - t0).toDouble();
      return start + (dt <= 11 ? 0.5 * dt * dt : 60.5 + 11 * (dt - 11));
    };

void main() {
  group('audit fixes', () {
    LiveTripState riding() =>
        advanceLive(nextLeg(_start()), _fix(_lat, _lon0, speed: 6)); // boarded

    test('arriving at the alight stop vibrates "scendi ora"', () {
      var s = riding();
      s = advanceLive(s, _fix(_lat, _lon0 + 2 * _step, speed: 6));
      expect(s.cue, LiveCue.oneStopLeft);
      final seq = s.cueSeq;
      // At the stop, still moving: "get off" now, but the rider is aboard.
      s = advanceLive(s, _fix(_lat, _lon0 + 3 * _step, speed: 6));
      expect(s.cue, LiveCue.alightNow);
      expect(s.cueSeq, greaterThan(seq));
      expect(s.finished, isFalse);
      // Stopped: off the vehicle, the journey is done - no second cue.
      final seq2 = s.cueSeq;
      s = advanceLive(s, _fix(_lat, _lon0 + 3 * _step, speed: 0.3));
      expect(s.finished, isTrue);
      expect(s.cueSeq, seq2);
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
    // Aboard ("Sono salito"), at the stop.
    s = advanceLive(nextLeg(s), _fix(_lat, _lon0, speed: 6));
    expect(s.legIndex, 1);
    expect(s.stopsRemaining, 3);

    s = advanceLive(s, _fix(_lat, _lon0 + _step, speed: 6));
    expect(s.stopsRemaining, 2);
    expect(s.cue, isNull);

    s = advanceLive(s, _fix(_lat, _lon0 + 2 * _step, speed: 6));
    expect(s.stopsRemaining, 1);
    expect(s.cue, LiveCue.oneStopLeft);

    // At the alight stop: the last cue fires; the journey ends once stopped.
    s = advanceLive(s, _fix(_lat, _lon0 + 3 * _step, speed: 6));
    expect(s.cue, LiveCue.alightNow);
    s = advanceLive(s, _fix(_lat, _lon0 + 3 * _step, speed: 0));
    expect(s.finished, isTrue);
  });

  test('a change on the same street: off the first bus, then onto the next',
      () {
    // Line 2 east A -> B; get off at B; walk back 30 m to T; line 9 from T
    // east along the same street. The early switch plus GPS noise used to
    // "board" line 9 while the rider was still on (or just off) line 2.
    final ix = syntheticIndex(
      stops: [
        ('A', 'A', _lat, 7.650),
        ('B', 'B', _lat, 7.660),
        ('T', 'T', _lat, 7.6596), // ~31 m before B
        ('F', 'F', _lat, 7.680),
      ],
      patterns: [
        ('2', RouteType.bus, ['A', 'B'], [[0, 300]]),
        ('9', RouteType.bus, ['T', 'F'], [[600, 900]]),
      ],
    );
    RideOption opt(String n, int p, int dep, int arr) => RideOption(
        routeShortName: n, routeType: RouteType.bus, pattern: p, trip: p,
        departure: dep, arrival: arr);
    final journey = Journey([
      Leg(kind: LegKind.ride, fromStop: 0, toStop: 1, departure: 0,
          arrival: 300, options: [opt('2', 0, 0, 300)]),
      const Leg(kind: LegKind.walk, fromStop: 1, toStop: 2, departure: 300,
          arrival: 330, walkMetres: 31),
      Leg(kind: LegKind.ride, fromStop: 2, toStop: 3, departure: 600,
          arrival: 900, options: [opt('9', 1, 600, 900)]),
    ], DateTime(2026, 9, 19));
    final route = buildLiveRoute(ix, null, journey);
    var s = LiveTripState(
      route: route,
      journey: journey,
      metresToEnd: route.legs.first.metres,
      stopsRemaining: route.legs.first.stopVertex.length,
    );
    // Aboard line 2, 40 m before B at bus speed: still riding, told to get off.
    s = advanceLive(s, _fix(_lat, 7.6595, speed: 7));
    expect(s.legIndex, 0);
    expect(s.cue, LiveCue.alightNow);
    // Stopped at B: off. Now the 31 m walk back to T.
    s = advanceLive(s, _fix(_lat, 7.660, speed: 0));
    expect(s.legIndex, 1);
    // Standing at B, GPS noise 40 m further along line 9's street, walking
    // pace: still walking - and never boarded by noise.
    s = advanceLive(s, _fix(_lat, 7.6605, speed: 0.8, at: _t(1)));
    s = advanceLive(s, _fix(_lat, 7.6601, speed: 0.2, at: _t(2)));
    expect(s.legIndex, 1);
    // Walks back to T and waits for line 9.
    s = advanceLive(s, _fix(_lat, 7.6596, speed: 1, at: _t(30)));
    expect(s.legIndex, 1);
    expect(s.reachedBoardStop, isTrue);
    // Line 9 comes; the rider is on it, pulling out of T.
    final (on9, boardedAt) =
        _feed(s, _busFrom(300), t0: 290, t1: 330, from: 7.6596);
    expect(on9.legIndex, 2);
    expect(on9.riding, isTrue);
    expect(boardedAt, isNotNull);
  });

  test('next to the matched vehicle at the stop is not aboard yet', () {
    // Reaching the bus at the stop is also what just missing it looks like.
    var s = _start();
    s = advanceLive(s, _fix(_lat, _lon0, speed: 1.1, at: _t(0)));
    s = advanceLive(s, _fix(_lat, _lon0, speed: 3, at: _t(1)),
        vehicleLat: _lat, vehicleLon: _lon0);
    expect(s.legIndex, 0);
  });

  group('boarding on the road (beta 5 report: never detected)', () {
    test('wait at the stop, the bus pulls out: aboard within seconds', () {
      var s = _start();
      // Standing at the stop: no speed, not boarded, but the stop is reached.
      for (var t = 0; t < 30; t++) {
        s = advanceLive(s, _fix(_lat, _lon0 + 0.0001, speed: 0, at: _t(t)));
      }
      expect(s.legIndex, 0);
      expect(s.reachedBoardStop, isTrue);
      // Phone reports no speed: the fixes' own times and places decide.
      final (r, boardedAt) = _feed(s, _busFrom(30), t0: 30, t1: 70);
      expect(r.legIndex, 1);
      expect(r.riding, isTrue);
      expect(boardedAt! - 30, lessThanOrEqualTo(15));
      expect(r.along, greaterThan(100));
    });

    test('sparse fixes: the bus is already 120 m down the line', () {
      var s = _start();
      s = advanceLive(s, _fix(_lat, _lon0 + 0.0001, speed: 0, at: _t(0)));
      s = advanceLive(s, _fix(_lat, _lon0 + 0.0016, speed: -1, at: _t(12)));
      expect(s.legIndex, 0, reason: 'one fix is not enough');
      s = advanceLive(s, _fix(_lat, _lon0 + 0.0030, speed: -1, at: _t(22)));
      expect(s.legIndex, 1);
      expect(s.along, greaterThan(200));
    });

    test('a GPS jump while waiting is not a ride', () {
      var s = _start();
      for (var t = 0; t < 10; t++) {
        s = advanceLive(s, _fix(_lat, _lon0, speed: 0, at: _t(t)));
      }
      // 80 m down the line in a second, then it sits there.
      for (var t = 10; t < 20; t++) {
        s = advanceLive(s, _fix(_lat, _lon0 + 80 * _lonPerMetre,
            speed: -1, accuracy: 30, at: _t(t)));
      }
      expect(s.legIndex, 0);
    });

    test('never at the stop: needs vehicle motion on the line', () {
      var s = _start();
      // Walking along the line past where the stop is, at walking pace.
      final (walked, b1) =
          _feed(s, (t) => 1.3 * t, t0: 0, t1: 120, speed: 1.3);
      expect(b1, isNull, reason: 'a walker on the pavement is not aboard');
      // Caught it at a stop further on: a bus from there.
      s = walked;
      final (r, b2) = _feed(s, _busFrom(130, start: 1.3 * 120),
          t0: 121, t1: 160, speed: 9);
      expect(b2, isNotNull, reason: 'moving like a bus, on its line');
      expect(r.riding, isTrue);
    });

    test('at the stop but off the line (another street) stays walking', () {
      var s = _start();
      s = advanceLive(s, _fix(_lat, _lon0, speed: 0, at: _t(0)));
      for (var t = 1; t < 30; t++) {
        s = advanceLive(s, _fix(_lat + 0.003, _lon0 + t * 11 * _lonPerMetre,
            speed: 11, at: _t(t)));
      }
      expect(s.legIndex, 0);
    });
  });

  group('running is not riding (rider report: sprinting "boarded")', () {
    test('sprinting up to the stop does not board', () {
      var s = _start(); // walk starts ~79 m before the stop, on the line
      final (r, b) = _feed(s, (t) => math.min(0, -79 + 7.0 * t),
          t0: 0, t1: 30, speed: 7);
      expect(b, isNull);
      expect(r.legIndex, 0);
    });

    test('chasing a bus that left, along its street, does not board', () {
      var s = _start();
      for (var t = 0; t < 10; t++) {
        s = advanceLive(s, _fix(_lat, _lon0, speed: 0, at: _t(t)));
      }
      // A hard 7 m/s for 20 s - faster and longer than most people manage.
      final (r, b) = _feed(s, (t) => 7.0 * (t - 10), t0: 10, t1: 30, speed: 7);
      expect(b, isNull);
      expect(r.legIndex, 0);
      // ...gives up, walks back: still waiting for the next one.
      expect(r.reachedBoardStop, isTrue);
    });

    test('sprinting toward the stop against the line does not board', () {
      // From 300 m down the line, running back to the stop.
      var s = _start(originLon: _lon0 + 300 * _lonPerMetre);
      final (r, b) = _feed(s, (t) => math.max(0, 300 - 7.0 * t),
          t0: 0, t1: 50, speed: 7);
      expect(b, isNull);
      expect(r.legIndex, 0);
    });

    test('movingLikeAVehicleOn: sustained, not a burst', () {
      List<BoardSample> trail(List<double> along) => [
            for (var i = 0; i < along.length; i++) (at: _t(i), along: along[i]),
          ];
      expect(movingLikeAVehicleOn(trail([0, 8, 16, 24, 32, 40, 48])), isTrue);
      expect(movingLikeAVehicleOn(trail([0, 7, 14, 21, 28, 35, 42])), isFalse);
      // Fast, but only over 3 s: not enough to tell.
      expect(movingLikeAVehicleOn(trail([0, 10, 20, 30])), isFalse);
      expect(movingLikeAVehicleOn(trail([5])), isFalse);
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

  test('the early warning can come two stops before', () {
    var s = advanceLive(nextLeg(_start()), _fix(_lat, _lon0, speed: 6), warnStops: 2);
    expect(s.stopsRemaining, 3);
    s = advanceLive(s, _fix(_lat, _lon0 + _step, speed: 6), warnStops: 2);
    expect(s.stopsRemaining, 2);
    expect(s.cue, LiveCue.oneStopLeft, reason: 'two stops out: warn now');
    final seq = s.cueSeq;
    s = advanceLive(s, _fix(_lat, _lon0 + 2 * _step, speed: 6), warnStops: 2);
    expect(s.cueSeq, seq, reason: 'warned once, not again at one stop');
  });

  test('the trip notification says the instruction in brief', () {
    var s = _start();
    expect(liveNotificationText(s), startsWith('A piedi verso Fermata 0 (il 2)'));
    s = s.copyWith(reachedBoardStop: true);
    expect(liveNotificationText(s), 'Aspetta il 2 a Fermata 0');
    s = advanceLive(nextLeg(_start()), _fix(_lat, _lon0, speed: 6));
    expect(liveNotificationText(s), 'Scendi a Fermata 3 tra 3 fermate');
    s = s.copyWith(stopsRemaining: 1);
    expect(liveNotificationText(s), 'Scendi alla prossima: Fermata 3');
    s = s.copyWith(stopsRemaining: 0);
    expect(liveNotificationText(s), 'Scendi ora a Fermata 3');
  });

  test('progress is monotone: a fix behind the rider does not rewind', () {
    var s = _start();
    s = advanceLive(nextLeg(s), _fix(_lat, _lon0, speed: 6));
    s = advanceLive(s, _fix(_lat, _lon0 + 2 * _step, speed: 6));
    final forward = s.vertex;
    s = advanceLive(s, _fix(_lat, _lon0 + _step, speed: 6));
    expect(s.vertex, forward);
  });

  test('a poor fix holds the position and says it is estimated', () {
    var s = _start();
    s = advanceLive(nextLeg(s), _fix(_lat, _lon0, speed: 6));
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
    s = advanceLive(nextLeg(s), _fix(_lat, _lon0, speed: 6, at: t0));
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
    s = advanceLive(nextLeg(s), _fix(_lat, _lon0, speed: 6, at: t0));
    final before = s.vertex;
    final s2 = staleLive(
      s,
      start.add(const Duration(seconds: 300)),
      serviceStart: start,
    );
    expect(s2.estimated, isTrue);
    expect(s2.vertex, greaterThan(before));
  });

  group('screen off on a walk (beta 11 report)', () {
    final start = DateTime(2026, 9, 19);

    test('no fix for a long while: the walk holds, marked a guess', () {
      final s = _start().copyWith(lastFix: start);
      final e = staleLive(s, start.add(const Duration(minutes: 30)),
          serviceStart: start);
      expect(e.estimated, isTrue);
      expect(e.along, s.along);
      expect(e.legIndex, 0);
    });

    test('a guess that ran ahead gives way to the next good fix', () {
      // A ride estimated to its last stop while the rider is at the second.
      var s = advanceLive(nextLeg(_start()), _fix(_lat, _lon0, speed: 6));
      s = staleLive(s.copyWith(lastFix: start), start.add(const Duration(minutes: 7)),
          serviceStart: start);
      expect(s.estimated, isTrue);
      expect(s.stopsRemaining, 0);
      s = advanceLive(s, _fix(_lat, _lon0 + _step, speed: 6));
      expect(s.estimated, isFalse);
      expect(s.stopsRemaining, 2);
      expect(s.legIndex, 1);
    });

    test('a real position still never rewinds', () {
      var s = advanceLive(nextLeg(_start()), _fix(_lat, _lon0, speed: 6));
      s = advanceLive(s, _fix(_lat, _lon0 + 3 * _step, speed: 6));
      final left = s.stopsRemaining;
      s = advanceLive(s, _fix(_lat, _lon0 + _step, speed: 6));
      expect(s.stopsRemaining, left);
    });
  });

  group('missed bus', () {
    final day = DateTime(2026, 9, 19);
    // The ride leaves at 60 s past midnight.
    final dep = day.add(const Duration(seconds: 60));

    test('asked only once the bus is 90 s gone and the rider is not aboard',
        () {
      final walking = _start();
      expect(nextRideLeg(walking)?.kind, LegKind.ride);
      expect(missedRide(walking, dep.add(const Duration(seconds: 60)), dep),
          isFalse);
      expect(missedRide(walking, dep.add(const Duration(seconds: 120)), dep),
          isTrue);
      final aboard = nextLeg(walking);
      expect(missedRide(aboard, dep.add(const Duration(minutes: 5)), dep),
          isFalse);
      expect(nextRideLeg(aboard), isNull);
    });

    test('a late bus moves the moment: watched with its delay', () {
      final late = dep.add(const Duration(minutes: 4));
      expect(missedRide(_start(), dep.add(const Duration(minutes: 3)), late),
          isFalse);
    });
  });

  group('metro: underground', () {
    final start = DateTime(2026, 9, 19);
    LiveTripState aboard() => nextLeg(_start(type: RouteType.metro),
        at: start.add(const Duration(seconds: 60)));

    test('only a metro ride is underground', () {
      expect(isUnderground(aboard()), isTrue);
      expect(isUnderground(_start(type: RouteType.metro)), isFalse,
          reason: 'still walking to the station');
      expect(isUnderground(nextLeg(_start())), isFalse);
    });

    test('no train in the feed: the timetable moves it, never off route', () {
      final s = aboard().copyWith(offRoute: true);
      final e = undergroundLive(s, start.add(const Duration(seconds: 240)),
          serviceStart: start);
      expect(e.offRoute, isFalse);
      expect(e.estimated, isTrue);
      expect(e.legIndex, 1);
      expect(e.along, greaterThan(s.along));
      // Late: the same moment is earlier along the line.
      final late = undergroundLive(s, start.add(const Duration(seconds: 240)),
          serviceStart: start, delaySeconds: 120);
      expect(late.along, lessThan(e.along));
    });

    test('the train\'s live position moves the rider', () {
      final s = aboard();
      final e = undergroundLive(s, start.add(const Duration(seconds: 90)),
          serviceStart: start,
          vehicleLat: _lat,
          vehicleLon: _lon0 + 2 * _step);
      expect(e.legIndex, 1);
      expect(e.stopsRemaining, 1);
      expect(e.cue, LiveCue.oneStopLeft);
      expect(e.offRoute, isFalse);
    });

    test('the train at the exit says "scendi ora" but stays on the ride', () {
      final e = undergroundLive(aboard(), start.add(const Duration(minutes: 7)),
          serviceStart: start,
          vehicleLat: _lat,
          vehicleLon: _lon0 + 3 * _step);
      expect(e.legIndex, 1);
      expect(e.finished, isFalse);
      expect(e.stopsRemaining, 0);
      expect(e.cue, LiveCue.alightNow);
    });
  });

  test('manual board and alight always work', () {
    var s = _start();
    s = nextLeg(s);
    expect(s.legIndex, 1);
    s = nextLeg(s);
    expect(s.finished, isTrue);
  });
}
