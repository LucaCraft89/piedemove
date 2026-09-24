/// Walk legs (phase 5): one feature per walk leg, access/egress included (the
/// bug was that the off-stop ends were never resolved), straight fallback
/// marked approximate, and a disk-cached solved path served offline.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/walk_costs.dart';
import 'package:piedemove/geo/walk_graph.dart';
import 'package:piedemove/geo/walk_router.dart';
import 'package:piedemove/routing/footpaths.dart';
import 'package:piedemove/routing/walk_legs.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/map/line_features.dart';
import 'package:piedemove/ui/map/map_style.dart';

import 'support/synthetic.dart';

void main() {
  final ix = syntheticIndex(
    stops: [('A', 'A', 45.0, 7.6), ('B', 'B', 45.01, 7.6), ('C', 'C', 45.02, 7.6)],
    patterns: [('9', RouteType.bus, ['A', 'B'], [[0, 60]])],
  );
  Leg walk(int from, int to, double m) => Leg(
      kind: LegKind.walk, fromStop: from, toStop: to, departure: 0, arrival: 60, walkMetres: m);
  final journey = Journey([
    walk(-1, 0, 120),
    Leg(kind: LegKind.ride, fromStop: 0, toStop: 1, departure: 60, arrival: 600),
    walk(1, 2, 90),
    walk(2, -1, 300),
  ], DateTime(2026, 9, 24));

  test('access, transfer and egress each emit a feature; ends come from the query', () {
    final fc = walkFeatures(ix, journey,
        path: (_) => null,
        originLat: 44.999, originLon: 7.599, destLat: 45.021, destLon: 7.601);
    final f = fc['features'] as List;
    expect(f.length, 3);
    expect(f.every((x) => x['properties']['approx'] == 1), isTrue);
    expect(f.first['geometry']['coordinates'].first, [7.599, 44.999]);
    expect(f.last['geometry']['coordinates'].last, [7.601, 45.021]);
  });

  test('without origin/destination the off-stop legs are skipped, not crashed', () {
    final fc = walkFeatures(ix, journey, path: (_) => null);
    expect((fc['features'] as List).length, 1);
  });

  test('solved path is not approx and dash spacing is shared', () {
    final fc = walkFeatures(ix, journey,
        path: (i) => i == 2 ? [[7.6, 45.01], [7.61, 45.015], [7.6, 45.02]] : null,
        originLat: 44.999, originLon: 7.599, destLat: 45.021, destLon: 7.601);
    final byApprox = [for (final x in fc['features']) x['properties']['approx']];
    expect(byApprox, [1, 0, 1]);
    final a = walkDash(walkWidth), b = walkDash(walkWidth + walkCasingExtra);
    expect((a[0] + a[1]) * walkWidth,
        closeTo((b[0] + b[1]) * (walkWidth + walkCasingExtra), 1e-9));
  });

  group('routeWalks', () {
    // One crooked pedestrian edge along the stops' meridian, 45.00 -> 45.02.
    final router = WalkRouter(WalkGraph.build(
      nodeLat: [4500000, 4502000],
      nodeLon: [760000, 760000],
      edges: [
        WalkEdgeSpec(0, 1, WalkFlags.make(WalkKind.path),
            geom: [4500500, 760100, 4501500, 760100]),
      ],
      osmTime: 1,
      bbox: [4499000, 759000, 4503000, 761000],
    ));
    final routes = WalkRoutes(router);
    Journey j(int rideDeparts, {double lat = 45.0, double lon = 7.6}) => Journey([
          walk(-1, 1, 1000).withWalk(walkMetres: 1000, arrival: 60),
          Leg(kind: LegKind.ride, fromStop: 1, toStop: 2, departure: rideDeparts, arrival: rideDeparts + 300),
          walk(2, -1, 50),
        ], DateTime(2026, 9, 24));

    test('replaces estimates by routed metres, keeps the path, re-times the journey', () {
      final out = routeWalks([j(3000)], ix, routes,
          origin: (45.0, 7.6), destination: (45.02, 7.6), capMetres: 5000);
      expect(out, hasLength(1));
      final legs = out.single.legs;
      expect(legs.first.route, isNotNull);
      expect(legs.first.walkMetres, closeTo(legs.first.route!.metres, 1e-6));
      expect(legs.first.walkMetres, greaterThan(1112)); // crooked: longer than the straight chord
      expect(legs.first.arrival - legs.first.departure,
          (legs.first.walkMetres / walkSpeedMetresPerSecond).round());
      expect(out.single.walkApproximate, isFalse);
      // and the map draws that very path, not a chord
      final fc = walkFeatures(ix, out.single,
          path: (_) => null, originLat: 45.0, originLon: 7.6, destLat: 45.02, destLon: 7.6);
      expect((fc['features'] as List).first['properties']['approx'], 0);
    });

    test('a journey whose real walk misses the connection is dropped, and the cap applies', () {
      expect(routeWalks([j(100)], ix, routes,
          origin: (45.0, 7.6), destination: (45.02, 7.6), capMetres: 5000), isEmpty);
      expect(routeWalks([j(3000)], ix, routes,
          origin: (45.0, 7.6), destination: (45.02, 7.6), capMetres: 500), isEmpty);
    });

    test('outside the graph: scaled estimate, unrouted, marked approximate', () {
      final out = routeWalks([j(3000)], ix, routes,
          origin: (46.0, 8.0), destination: (46.02, 8.0), capMetres: 5000);
      expect(out.single.legs.first.route, isNull);
      expect(out.single.legs.first.walkMetres, closeTo(1000 * walkDetourFactor, 1e-6));
      expect(out.single.walkApproximate, isTrue);
      expect(routeWalks([j(3000)], ix, null,
              origin: (45.0, 7.6), destination: (45.02, 7.6), capMetres: 5000)
          .single.walkApproximate, isTrue);
    });
  });
}
