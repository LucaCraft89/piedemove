import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/walk_router.dart';
import 'package:piedemove/geo/walk_graph.dart';
import 'package:piedemove/routing/footpaths.dart';
import 'package:piedemove/routing/walk_legs.dart';
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
  late WalkRoutes routes;
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
    final request = PlanRequest(
      originLat: ix.stopLat[politecnico],
      originLon: ix.stopLon[politecnico],
      destLat: 45.0738,
      destLon: 7.6400,
      when: DateTime(day.year, day.month, day.day, 18),
    );
    // The app's pipeline: the planner proposes, the shipped walking graph
    // prices every walk leg (routed metres are what is shown and scored).
    final asset = File('assets/walk_graph.pmwg.gz');
    routes = WalkRoutes(WalkRouter(
        WalkGraph.decode(Uint8List.fromList(gzip.decode(asset.readAsBytesSync())))));
    journeys = routeWalks(
      planner.plan(request.withWalkCap(request.walkCapMetres * walkDetourFactor)),
      ix,
      routes,
      origin: (request.originLat, request.originLon),
      destination: (request.destLat, request.destLon),
      capMetres: request.walkCapMetres,
      retime: (leg, ready, date) => planner.retimeRide(leg, ready, request, date),
      maxExtraSeconds: request.maxExtraMinutes * 60,
    );
    for (final j in sortBalanced(journeys).take(3)) {
      // ignore: avoid_print
      print('journey walk ${j.walkMetres.round()} m: ${j.legs.map((l) => l.kind == LegKind.walk ? "walk ${l.walkMetres.round()}${l.route == null ? "~" : ""}" : l.options.map((o) => o.routeShortName).join("/")).join(" > ")}');
    }
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

  test('the pinned hop, routed on real pedestrian edges, stays a short one', () {
    final trapani = ix.stopIndexById['3694']!;
    final peschiera = ix.stopIndexById['230']!;
    final r = routes.route(ix.stopLat[trapani], ix.stopLon[trapani],
        ix.stopLat[peschiera], ix.stopLon[peschiera])!;
    // ignore: avoid_print
    print('TRAPANI 872 -> PESCHIERA 120 routed: ${r.metres.round()} m');
    expect(r.metres, inInclusiveRange(110, 260));
  }, skip: skip);

  test('the balanced best rides line 2 to within ~300 m of Via Cristalliera', () {
    expect(journeys, isNotEmpty, reason: 'no journey at all');
    final best = sortBalanced(journeys).first;
    final lastRide = best.legs.lastWhere((l) => l.kind == LegKind.ride);
    expect(lastRide.options.map((o) => o.routeShortName), contains('2'));
    // With routed distances BARDONECCHIA (300 m, the user's 320 m by hand) and
    // RIVOLI SUD (298 m) tie; the straight line used to favour BARDONECCHIA.
    expect(best.legs.last.walkMetres, lessThanOrEqualTo(330));
    expect(best.legs.last.route, isNotNull, reason: 'egress must be a routed path');
    // BARDONECCHIA itself is still on offer.
    final bardonecchia = {ix.stopIndexById['208']!, ix.stopIndexById['219']!};
    expect(
        journeys.any((j) => j.legs
            .any((l) => l.kind == LegKind.ride && bardonecchia.contains(l.toStop))),
        isTrue);
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
    // Another trip (to Porta Nuova): merged same-line splits leave the golden
    // set without a shared hop, so check the post-pass on a busy corridor.
    final busy = planner.plan(PlanRequest(
      originLat: ix.stopLat[ix.stopIndexById['3454']!],
      originLon: ix.stopLon[ix.stopIndexById['3454']!],
      destLat: 45.0620,
      destLon: 7.6780,
      when: DateTime(2026, 9, 25, 12),
    ));
    final multi = [...journeys, ...busy]
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
