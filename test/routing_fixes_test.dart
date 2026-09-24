// Regression tests for the 2026-09 audit fixes in lib/routing.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/routing/footpaths.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/routing/raptor.dart';

import 'support/synthetic.dart';

const _h = 3600;
const _m = 60;

void main() {
  final date = syntheticDate();
  DateTime at(int h, int m) => DateTime(date.year, date.month, date.day, h, m);

  test('a later trip boarded upstream does not prune an earlier one here', () {
    // X is 100 m from the origin, Y 300 m. Leaving at 08:01, T1 has left X but
    // is still catchable at Y (08:10); T2 is boarded at X (08:08) and passes Y
    // at 08:18. Comparing T2's X departure with T1's Y departure hid T1.
    final ix = syntheticIndex(
      stops: [
        ('X', 'XRAY', 45.0009, 7.6000),
        ('Y', 'YANKEE', 44.9973, 7.6000),
        ('Z', 'ZULU', 45.0300, 7.6000),
      ],
      patterns: [
        ('9', 3, ['X', 'Y', 'Z'], [
          [8 * _h, 8 * _h + 10 * _m, 8 * _h + 20 * _m],
          [8 * _h + 8 * _m, 8 * _h + 18 * _m, 8 * _h + 28 * _m],
        ]),
      ],
    );
    final journeys = Planner(ix, Footpaths.build(ix)).plan(PlanRequest(
      originLat: 45.0,
      originLon: 7.6,
      destLat: 45.03,
      destLon: 7.6,
      when: at(8, 1),
    ));
    final arrivals = journeys.map((j) => j.arrival).toSet();
    expect(arrivals, contains(8 * _h + 20 * _m));
    expect(arrivals, contains(8 * _h + 28 * _m));
  });

  group('arrive-by', () {
    final ix = syntheticIndex(
      stops: [
        ('A', 'ALFA', 45.0000, 7.6000),
        ('C', 'CHARLIE', 45.0200, 7.6000),
      ],
      patterns: [
        ('1', 3, ['A', 'C'], [
          [7 * _h, 7 * _h + 10 * _m],
          [8 * _h, 8 * _h + 10 * _m],
          [9 * _h, 9 * _h + 10 * _m],
          [10 * _h, 10 * _h + 10 * _m],
        ]),
      ],
    );
    final planner = Planner(ix, Footpaths.build(ix));
    PlanRequest byDeadline(int h, int m) => PlanRequest(
          originLat: 45.0005,
          originLon: 7.6,
          destLat: 45.02,
          destLon: 7.6,
          when: at(h, m),
          arriveBy: true,
        );

    test('takes the last run that still lands in time', () {
      final js = planner.plan(byDeadline(9, 15));
      expect(js, isNotEmpty);
      final ride = js.first.legs.firstWhere((l) => l.kind == LegKind.ride);
      expect(ride.departure, 9 * _h);
      for (final j in js) {
        expect(j.arrival, lessThanOrEqualTo(9 * _h + 15 * _m));
      }
    });

    test('the access walk leaves as late as the ride allows', () {
      final j = planner.plan(byDeadline(9, 15)).first;
      final walk = j.legs.first;
      expect(walk.kind, LegKind.walk);
      expect(walk.arrival, 9 * _h - arriveByBoardBufferSeconds);
    });

    test('nothing lands in time: no journey', () {
      expect(planner.plan(byDeadline(7, 5)), isEmpty);
    });
  });

  test('a regional line does not merge with the GTT line of the same number',
      () {
    final ix = syntheticIndex(
      stops: [
        ('A', 'ALFA', 45.0000, 7.6000),
        ('C', 'CHARLIE', 45.0200, 7.6000),
      ],
      patterns: [
        ('2', 0, ['A', 'C'], [
          [8 * _h + 5 * _m, 8 * _h + 15 * _m],
        ]),
        ('2', 3, ['A', 'C'], [
          [8 * _h, 8 * _h + 12 * _m],
        ]),
      ],
      regionalPatterns: {1},
    );
    final js = Planner(ix, Footpaths.build(ix)).plan(PlanRequest(
      originLat: 45.0,
      originLon: 7.6,
      destLat: 45.02,
      destLon: 7.6,
      when: at(7, 55),
    ));
    final ride = js.expand((j) => j.legs).firstWhere((l) => l.kind == LegKind.ride);
    expect(ride.options, hasLength(2));
    expect(ride.options.where((o) => o.scheduledOnly), hasLength(1));
  });

  test('a connection after midnight uses the next service day', () {
    final ix = syntheticIndex(
      stops: [
        ('A', 'ALFA', 45.0000, 7.6000),
        ('B', 'BRAVO', 45.0200, 7.6000),
        ('C', 'CHARLIE', 45.0400, 7.6000),
      ],
      patterns: [
        ('N', 3, ['A', 'B'], [
          [23 * _h + 50 * _m, 24 * _h + 10 * _m],
        ]),
        // Only runs early morning; reached from B after midnight.
        ('5', 3, ['B', 'C'], [
          [5 * _h, 5 * _h + 10 * _m],
        ]),
      ],
    );
    final js = Planner(ix, Footpaths.build(ix)).plan(PlanRequest(
      originLat: 45.0,
      originLon: 7.6,
      destLat: 45.04,
      destLon: 7.6,
      when: at(23, 45),
      maxExtraMinutes: 24 * 60,
    ));
    expect(js.map((j) => j.arrival), contains(24 * _h + 5 * _h + 10 * _m));
  });

  test('cluster footpaths never exceed the footpath radius', () {
    // Five same-name poles 140 m apart chain into one 560 m display cluster.
    final ix = syntheticIndex(
      stops: [
        for (var i = 0; i < 5; i++) ('s$i', 'PIAZZA', 45.0 + i * 0.00126, 7.6),
      ],
      patterns: [],
    );
    final fp = Footpaths.build(ix);
    for (var i = 0; i < fp.metres.length; i++) {
      expect(fp.metres[i], lessThanOrEqualTo(footpathRadiusMetres));
    }
  });

  group('departures', () {
    final ix = syntheticIndex(
      stops: [
        ('A', 'ALFA', 45.0000, 7.6000),
        ('C', 'CHARLIE', 45.0200, 7.6000),
      ],
      patterns: [
        ('1', 3, ['A', 'C'], [
          [1 * _h + 30 * _m, 1 * _h + 40 * _m],
          [8 * _h, 8 * _h + 10 * _m],
        ]),
      ],
    );

    test('a late bus stays listed until its expected time', () {
      final next = nextDepartures(ix, 0, at(8, 2), 5,
          delays: (trip, pos) => 5 * _m);
      expect(next.first.scheduled, 8 * _h);
      expect(next.first.expected, 8 * _h + 5 * _m);
    });

    test('an early bus leaves the list once its expected time passed', () {
      final next = nextDepartures(ix, 0, at(7, 59), 5,
          delays: (trip, pos) => -2 * _m);
      expect(next.where((d) => d.scheduled == 8 * _h), isEmpty);
    });

    test('a late-evening horizon reaches tomorrow morning', () {
      final next = nextDepartures(ix, 0, at(23, 30), 5);
      expect(next.map((d) => d.scheduled), contains(24 * _h + 1 * _h + 30 * _m));
      final t = next.first.time;
      expect((t.hour, t.minute), (1, 30));
      expect(t.day, isNot(date.day));
    });
  });

  test('service-day seconds read as wall-clock time on a DST change day', () {
    // Last Sunday of March and of October (Europe/Rome changes then; CI runs
    // the suite with TZ=Europe/Rome so this bites there).
    for (final day in [DateTime(2026, 3, 29), DateTime(2026, 10, 25)]) {
      final t = serviceDayTime(day, 8 * _h + 15 * _m);
      expect((t.day, t.hour, t.minute), (day.day, 8, 15));
      final late = serviceDayTime(day, 25 * _h);
      expect((late.day, late.hour), (day.day + 1, 1));
    }
  });

  test('the day index helper still maps the synthetic start', () {
    expect(TransitIndex.epochDay(syntheticDate()), 20001);
  });
}
