import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/routing/footpaths.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/routing/raptor.dart';

/// The golden case, against the real index: POLITECNICO -> Via Cristalliera.
/// Google answers "33/42 then walk" — one ride and a ~520 m walk from TRAPANI.
/// PiedeMove must instead reach line 2 through short footpath transfers and
/// alight at BARDONECCHIA, walking far less.
///
/// Structure and stop ids are pinned, times never are: the feed is regenerated
/// daily. The pinned footpath (TRAPANI 872 -> PESCHIERA 120, 126 m) is asserted
/// on the footpath table itself, because whether that particular hop is the
/// *best* journey depends on the day's timetable.
void main() {
  const indexPath = 'build/index.bin';
  final missing = !File(indexPath).existsSync();
  final skip = missing ? 'run `dart tool/build_index.dart` first' : null;

  late TransitIndex ix;
  late Footpaths footpaths;
  late Planner planner;
  late List<Journey> journeys;

  setUpAll(() async {
    if (missing) return;
    ix = (await readIndexFile(indexPath))!;
    footpaths = Footpaths.build(ix);
    planner = Planner(ix, footpaths);

    final politecnico = ix.stopIndexById['3454']!; // pole 670
    var day = DateTime.now();
    while (day.weekday > DateTime.friday) {
      day = day.add(const Duration(days: 1));
    }
    journeys = planner.plan(PlanRequest(
      originLat: ix.stopLat[politecnico],
      originLon: ix.stopLon[politecnico],
      destLat: 45.0738,
      destLon: 7.6400,
      when: DateTime(day.year, day.month, day.day, 18),
    ));
  });

  test('the 126 m TRAPANI -> PESCHIERA footpath exists', () {
    final trapani = ix.stopIndexById['3694']!; // pole 872
    final peschiera = ix.stopIndexById['230']!; // pole 120
    final edge = [
      for (var i = footpaths.offset[trapani];
          i < footpaths.offset[trapani + 1];
          i++)
        if (footpaths.target[i] == peschiera) footpaths.metres[i],
    ];
    expect(edge, hasLength(1));
    expect(edge.single, closeTo(126, 15));
  }, skip: skip);

  test('the balanced best rides line 2 into BARDONECCHIA', () {
    expect(journeys, isNotEmpty, reason: 'no journey at all');
    final best = sortBalanced(journeys).first;
    final bardonecchia = {ix.stopIndexById['208']!, ix.stopIndexById['219']!};
    final lastRide = best.legs.lastWhere((l) => l.kind == LegKind.ride);
    expect(bardonecchia, contains(lastRide.toStop));
    expect(lastRide.options.map((o) => o.routeShortName), contains('2'));
  }, skip: skip);

  test('it gets there on footpath transfers, not on a long walk', () {
    final best = sortBalanced(journeys).first;
    final transfers = best.legs.where((l) =>
        l.kind == LegKind.walk && l.fromStop >= 0 && l.toStop >= 0);
    expect(transfers, isNotEmpty, reason: 'no footpath transfer used');
    for (final t in transfers) {
      expect(t.walkMetres, lessThanOrEqualTo(200));
    }

    // Google's answer is in the same result set: one ride, then walk from
    // TRAPANI. It must cost strictly more walking than the chosen journey.
    final trapani = {ix.stopIndexById['3693']!, ix.stopIndexById['3694']!};
    final rideAndWalk = journeys.where((j) {
      final rides = j.legs.where((l) => l.kind == LegKind.ride).toList();
      return rides.length == 1 && trapani.contains(rides.single.toStop);
    }).toList();
    expect(rideAndWalk, isNotEmpty,
        reason: 'the 33-then-walk journey should still be offered');
    for (final j in rideAndWalk) {
      expect(best.walkMetres, lessThan(j.walkMetres));
      expect(j.legs.last.walkMetres, greaterThan(400));
    }
  }, skip: skip);

  test('a ride leg carries every line that makes the hop', () {
    final multi = journeys
        .expand((j) => j.legs)
        .where((l) => l.kind == LegKind.ride && l.options.length > 1);
    expect(multi, isNotEmpty,
        reason: 'the every-line post-pass collapsed every leg to one route');
    // Each option is a distinct line with its own next departure.
    for (final leg in multi) {
      final names = leg.options.map((o) => o.routeShortName).toList();
      expect(names.toSet(), hasLength(names.length));
      for (final o in leg.options) {
        expect(o.departure, greaterThanOrEqualTo(leg.readyTime));
      }
    }
  }, skip: skip);

  test('orderings hold on real data', () {
    final fast = sortFastest(journeys);
    final balanced = sortBalanced(journeys);
    expect(fast.first.arrival, lessThanOrEqualTo(balanced.first.arrival));
    expect(balanced.first.walkMetres, lessThanOrEqualTo(fast.first.walkMetres));
  }, skip: skip);
}
