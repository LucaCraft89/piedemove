// A stop picked in search is the whole stop: one row per stop, and the
// planner treats every pole (usually one per direction) as "here".
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/clustering.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/places/search_index.dart';
import 'package:piedemove/routing/footpaths.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/routing/raptor.dart';
import 'package:piedemove/routing/walk_legs.dart';

import 'support/synthetic.dart';

const _h = 3600;
const _m = 60;

void main() {
  final date = syntheticDate();
  DateTime at(int h, int m) => DateTime(date.year, date.month, date.day, h, m);

  // PIAZZA: pole N (northbound side) and pole S across the street, ~45 m
  // apart. Line 1 leaves from S towards FAR; line 1 back arrives at N.
  // FAR has two poles too: F1 where line 1 stops, F2 45 m away, unserved
  // by it.
  final ix = syntheticIndex(
    stops: [
      ('N', 'PIAZZA', 45.0000, 7.6000),
      ('S', 'PIAZZA', 45.0004, 7.6000),
      ('F1', 'FAR', 45.0300, 7.6000),
      ('F2', 'FAR', 45.0304, 7.6000),
      ('Q', 'ALTROVE', 45.0600, 7.6000),
      ('W', 'VIA', 45.0010, 7.6000), // 67 m past S, 111 m past N
    ],
    patterns: [
      ('1', RouteType.bus, ['S', 'F1'], [
        [8 * _h, 8 * _h + 10 * _m],
      ]),
      ('1', RouteType.bus, ['F1', 'N'], [
        [9 * _h, 9 * _h + 10 * _m],
      ]),
      ('7', RouteType.bus, ['F2', 'Q'], [
        [10 * _h, 10 * _h + 10 * _m],
      ]),
      ('9', RouteType.bus, ['W', 'Q'], [
        [11 * _h, 11 * _h + 10 * _m],
      ]),
    ],
  );
  final clusters = StopClusters.build(ix);
  final planner = Planner(ix, Footpaths.build(ix));
  int s(String id) => ix.stopIds.indexOf(id);

  test('search lists a stop once, with every pole', () {
    final groups = searchStopGroups(ix, clusters, 'piazza',
        lat: 45.0, lon: 7.6);
    expect(groups, hasLength(1));
    expect(groups.single.toSet(), {s('N'), s('S')});
    expect(groups.single.first, s('N'), reason: 'nearest pole first');
  });

  test('a saved stop resolves by name and place, not index', () {
    expect(clusters.groupAt(ix, 'PIAZZA', 45.0001, 7.6).toSet(),
        {s('N'), s('S')});
    expect(clusters.groupAt(ix, 'PIAZZA', 45.05, 7.6), isEmpty,
        reason: 'same name far away is another stop');
    expect(clusters.groupAt(ix, 'RENAMED', 45.0, 7.6), isEmpty);
  });

  test('a stop place round-trips through JSON', () {
    const p = Place(name: 'PIAZZA', address: 'Fermate N · S', lat: 45, lon: 7.6,
        stop: true);
    expect(Place.fromJson(p.toJson()).stop, isTrue);
    expect(
        Place.fromJson(const Place(name: 'x', address: '', lat: 0, lon: 0)
                .toJson())
            .stop,
        isFalse);
  });

  PlanRequest req({List<int> from = const [], List<int> to = const []}) =>
      PlanRequest(
        // The point is pole N, the wrong side for line 1 to FAR.
        originLat: ix.stopLat[s('N')],
        originLon: ix.stopLon[s('N')],
        destLat: ix.stopLat[s('F2')],
        destLon: ix.stopLon[s('F2')],
        when: at(7, 50),
        originStops: from,
        destStops: to,
      );

  test('as a point, the other side costs a walk across the street', () {
    final j = planner.plan(req()).first;
    expect(j.legs.first.kind, LegKind.walk);
    expect(j.legs.first.walkMetres, greaterThan(30));
    expect(j.walkMetres, greaterThan(70), reason: 'both ends walk');
  });

  test('as a stop, the planner boards on the side the trip needs, 0 m', () {
    final from = clusters.groupAt(ix, 'PIAZZA', ix.stopLat[s('N')],
        ix.stopLon[s('N')]);
    final to = clusters.groupAt(ix, 'FAR', ix.stopLat[s('F2')],
        ix.stopLon[s('F2')]);
    final j = planner.plan(req(from: from, to: to)).first;
    final ride = j.legs.firstWhere((l) => l.kind == LegKind.ride);
    expect(ride.fromStop, s('S'));
    expect(ride.toStop, s('F1'));
    expect(j.walkMetres, 0);
    // No walk from the group's point to the pole it boards at.
    expect(j.legs.first.kind, LegKind.ride);
    // Arriving at any pole is arriving: the last walk ends at F1 itself.
    expect(j.legs.last.placeStop, s('F1'));
    final ends = walkLegEnds(ix, j.legs.last,
        origin: (0.0, 0.0), destination: (0.0, 0.0));
    expect(ends!.$2, (ix.stopLat[s('F1')], ix.stopLon[s('F1')]));
  });

  test('any pole of the stop boards at 0 m', () {
    final from = clusters.groupAt(ix, 'FAR', ix.stopLat[s('F1')],
        ix.stopLon[s('F1')]);
    final j = planner
        .plan(PlanRequest(
          originLat: ix.stopLat[s('F1')],
          originLon: ix.stopLon[s('F1')],
          destLat: ix.stopLat[s('Q')],
          destLon: ix.stopLon[s('Q')],
          when: at(9, 50),
          originStops: from,
        ))
        .first;
    expect(j.legs.first.kind, LegKind.ride);
    expect(j.legs.first.fromStop, s('F2'));
  });

  test('a walk to another stop starts from the nearest pole', () {
    final from = clusters.groupAt(ix, 'PIAZZA', ix.stopLat[s('N')],
        ix.stopLon[s('N')]);
    final j = planner
        .plan(PlanRequest(
          originLat: ix.stopLat[s('N')],
          originLon: ix.stopLon[s('N')],
          destLat: ix.stopLat[s('Q')],
          destLon: ix.stopLon[s('Q')],
          when: at(10, 50),
          originStops: from,
        ))
        .first;
    final access = j.legs.first;
    expect(access.kind, LegKind.walk);
    expect(access.toStop, s('W'));
    expect(access.placeStop, s('S'), reason: 'S is the nearer pole');
    expect(access.walkMetres, closeTo(67, 5));
  });
}
