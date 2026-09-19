import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/clustering.dart';
import 'package:piedemove/data/csv.dart';
import 'package:piedemove/data/index_build.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/routing/footpaths.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/routing/raptor.dart';
import 'package:piedemove/routing/score.dart';

import 'support/synthetic.dart';

const _h = 3600;

/// A -> C on line 1; B -> D on line 2. A and B are 111 m apart, C and D 400 m,
/// so the walk-cheap answer is the footpath at the start, not at the end.
TransitIndex _tiny() => syntheticIndex(
      stops: [
        ('A', 'ALFA', 45.0000, 7.6000),
        ('B', 'BRAVO', 45.0010, 7.6000),
        ('C', 'CHARLIE', 45.0200, 7.6000),
        ('D', 'DELTA', 45.0236, 7.6000),
      ],
      patterns: [
        ('1', 3, ['A', 'C'], [
          [8 * _h, 8 * _h + 600],
          [9 * _h, 9 * _h + 600],
        ]),
        ('2', 0, ['B', 'D'], [
          [8 * _h + 300, 8 * _h + 900],
        ]),
        // Same hop as line 1, a few minutes later: the every-line post-pass
        // must report both lines on the leg.
        ('3', 3, ['A', 'C'], [
          [8 * _h + 120, 8 * _h + 780],
        ]),
      ],
    );

void main() {
  group('gtfs parsing', () {
    test('times past midnight', () {
      expect(parseGtfsTime('00:00:00'), 0);
      expect(parseGtfsTime('08:05:30'), 8 * 3600 + 330);
      expect(parseGtfsTime('25:10:00'), 25 * 3600 + 600);
    });

    test('quoted csv fields', () {
      expect(parseCsvLine('"a","b,c","d""e"'), ['a', 'b,c', 'd"e']);
    });

    test('stop names lose the Fermata prefix', () {
      expect(cleanStopName('Fermata 872 - TRAPANI'), 'TRAPANI');
      expect(cleanStopName('TRAPANI'), 'TRAPANI');
    });
  });

  test('index survives a binary round trip', () {
    final ix = _tiny();
    final back = decodeIndex(encodeIndex(ix));
    expect(back.stopIds, ix.stopIds);
    expect(back.stopNames, ix.stopNames);
    expect(back.patternCount, ix.patternCount);
    expect(back.tripDep, ix.tripDep);
    expect(back.depOf(0, 1), 8 * _h + 600);
  });

  test('footpaths connect nearby stops and skip far ones', () {
    final ix = _tiny();
    final fp = Footpaths.build(ix);
    final neighbours = [
      for (var i = fp.offset[0]; i < fp.offset[1]; i++) fp.target[i],
    ];
    expect(neighbours, contains(1)); // A -> B, ~111 m
    expect(neighbours, isNot(contains(2))); // A -> C, ~2.2 km
  });

  test('clusters need the same name and 150 m', () {
    final ix = syntheticIndex(
      stops: [
        ('a', 'TRAPANI', 45.0000, 7.6000),
        ('b', 'TRAPANI', 45.0005, 7.6000), // 55 m
        ('c', 'TRAPANI', 45.0100, 7.6000), // 1.1 km
      ],
      patterns: [],
    );
    final clusters = StopClusters.build(ix);
    expect(clusters.clusterOfStop[0], clusters.clusterOfStop[1]);
    expect(clusters.clusterOfStop[0], isNot(clusters.clusterOfStop[2]));
  });

  group('planner', () {
    final ix = _tiny();
    final fp = Footpaths.build(ix);
    final planner = Planner(ix, fp);
    final date = syntheticDate();

    PlanRequest request({double walkCap = 800}) => PlanRequest(
          originLat: 45.0000,
          originLon: 7.6000,
          destLat: 45.0236,
          destLon: 7.6000,
          when: DateTime(date.year, date.month, date.day, 7, 50),
          walkCapMetres: walkCap,
        );

    test('finds the footpath answer and walks less than the ride-through', () {
      final journeys = planner.plan(request());
      expect(journeys, isNotEmpty);
      final balanced = sortBalanced(journeys);
      final best = balanced.first;
      expect(best.rides, 1);
      expect(best.legs.any((l) => l.kind == LegKind.ride &&
          l.options.any((o) => o.routeShortName == '2')), isTrue);
      final rideThrough = journeys.where((j) => j.legs.any((l) =>
          l.kind == LegKind.ride &&
          l.options.every((o) => o.routeShortName != '2')));
      for (final j in rideThrough) {
        expect(best.walkMetres, lessThan(j.walkMetres));
      }
    });

    test('a ride leg lists every line that makes the hop', () {
      final journeys = planner.plan(PlanRequest(
        originLat: 45.0000,
        originLon: 7.6000,
        destLat: 45.0200,
        destLon: 7.6000,
        when: DateTime(date.year, date.month, date.day, 7, 50),
      ));
      final ride = journeys
          .expand((j) => j.legs)
          .firstWhere((l) => l.kind == LegKind.ride);
      expect(ride.options.map((o) => o.routeShortName), containsAll(['1', '3']));
    });

    test('a walk cap below the footpath leaves no journey', () {
      final journeys = planner.plan(request(walkCap: 50));
      expect(journeys, isEmpty);
    });

    test('orderings agree with their own invariants', () {
      final journeys = planner.plan(request());
      final fast = sortFastest(journeys);
      final balanced = sortBalanced(journeys);
      for (var i = 1; i < fast.length; i++) {
        expect(fast[i - 1].arrival, lessThanOrEqualTo(fast[i].arrival));
      }
      double s(Journey j) => score(
            walkMetres: j.walkMetres,
            durationMinutes: j.durationSeconds / 60,
            detoured: j.detoured,
          );
      for (var i = 1; i < balanced.length; i++) {
        expect(s(balanced[i - 1]), lessThanOrEqualTo(s(balanced[i])));
      }
      expect(fast.first.arrival, lessThanOrEqualTo(balanced.first.arrival));
      expect(balanced.first.walkMetres,
          lessThanOrEqualTo(fast.first.walkMetres));
    });

    test('a suspended stop is never boarded', () {
      final journeys = planner.plan(PlanRequest(
        originLat: 45.0000,
        originLon: 7.6000,
        destLat: 45.0236,
        destLon: 7.6000,
        when: DateTime(date.year, date.month, date.day, 7, 50),
        suspendedStops: {ix.stopIndexById['B']!},
      ));
      for (final j in journeys) {
        for (final leg in j.legs) {
          expect(leg.fromStop, isNot(ix.stopIndexById['B']));
          expect(leg.toStop, isNot(ix.stopIndexById['B']));
        }
      }
    });

    test('a detoured line pays the flat penalty', () {
      expect(
        score(walkMetres: 100, durationMinutes: 10, detoured: true) -
            score(walkMetres: 100, durationMinutes: 10),
        detourPenalty,
      );
    });
  });

  group('departures', () {
    final ix = _tiny();
    final date = syntheticDate();

    test('soonest first, across patterns', () {
      final next = nextDepartures(
          ix, 0, DateTime(date.year, date.month, date.day, 7, 0), 5);
      expect(next.map((d) => d.routeShortName), ['1', '3', '1']);
      expect(next.first.scheduled, 8 * _h);
      expect(next.first.headsign, 'CHARLIE');
    });

    test('a trip that started yesterday still shows after midnight', () {
      final night = syntheticIndex(
        stops: [
          ('A', 'ALFA', 45.0, 7.6),
          ('B', 'BRAVO', 45.01, 7.6),
        ],
        patterns: [
          ('N1', 3, ['A', 'B'], [
            [25 * _h, 25 * _h + 600], // 01:00 of the next calendar day
          ]),
        ],
      );
      final tomorrow = TransitIndex.dateOfEpochDay(
          TransitIndex.epochDay(syntheticDate()) + 1);
      final next = nextDepartures(night, 0,
          DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 0, 30), 5);
      expect(next, hasLength(1));
      expect(next.first.scheduled, 3600); // 01:00 today
    });

    test('realtime delay moves the expected time', () {
      final next = nextDepartures(
        ix,
        0,
        DateTime(date.year, date.month, date.day, 7, 0),
        1,
        delays: (trip, pos) => 120,
      );
      expect(next.first.live, isTrue);
      expect(next.first.expected, next.first.scheduled + 120);
    });
  });
}
