/// Pedestrian router on synthetic graphs: crossing preference, steps penalty,
/// mid-edge snapping, no jaywalking across a motorway, maneuvers, re-route,
/// plus the file format (header, version, hash, determinism).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/geo/walk_build.dart';
import 'package:piedemove/geo/walk_costs.dart';
import 'package:piedemove/geo/walk_graph.dart';
import 'package:piedemove/geo/walk_router.dart';

// A flat test world near 45N: x east, y north, both in metres.
const _lat0 = 4500000, _lon0 = 760000;
int _la(double y) => _lat0 + (y / 1.111949).round();
int _lo(double x) => _lon0 + (x / (1.111949 * 0.7071)).round();
double latOf(double y) => _la(y) / walkCoordScale;
double lonOf(double x) => _lo(x) / walkCoordScale;

class _B {
  final lat = <int>[], lon = <int>[];
  final edges = <WalkEdgeSpec>[];
  int node(double x, double y) {
    lat.add(_la(y));
    lon.add(_lo(x));
    return lat.length - 1;
  }

  void edge(int a, int b, int flags, {String? name, List<(double, double)> via = const []}) {
    edges.add(WalkEdgeSpec(a, b, flags, name: name, geom: [
      for (final (x, y) in via) ...[_la(y), _lo(x)]
    ]));
  }

  WalkGraph build() => WalkGraph.build(
        nodeLat: lat,
        nodeLon: lon,
        edges: edges,
        osmTime: 1700000000,
        bbox: [_la(-1000), _lo(-1000), _la(1000), _lo(1000)],
      );
}

final _path = WalkFlags.make(WalkKind.path);
int _cross(int type) => WalkFlags.make(WalkKind.crossing, sub: type);
final _steps = WalkFlags.make(WalkKind.steps);

void main() {
  group('costs', () {
    test('controlled < zebra < uncontrolled < unmarked, steps and covered', () {
      expect(crossSignalsMetres, lessThan(crossZebraMetres));
      expect(crossZebraMetres, lessThanOrEqualTo(crossUncontrolledMetres));
      expect(crossUncontrolledMetres, lessThan(crossUnmarkedMetres));
      expect(walkEdgeCost(_steps, 10), greaterThan(walkEdgeCost(_path, 10) * 2));
      expect(walkEdgeCost(WalkFlags.make(WalkKind.path, covered: true), 10),
          lessThan(10));
    });
  });

  group('router', () {
    test('prefers a signalised crossing over an unmarked shortcut, until the detour is huge', () {
      WalkRoute? go(double detour) {
        final b = _B();
        final a = b.node(0, 0), west = b.node(0, detour), east = b.node(12, detour), end = b.node(12, 0);
        b.edge(a, west, _path);
        b.edge(west, east, _cross(WalkCrossing.signals));
        b.edge(east, end, _path);
        b.edge(a, end, _cross(WalkCrossing.unmarked)); // the shortcut
        return WalkRouter(b.build()).route(latOf(0), lonOf(0), latOf(0), lonOf(12));
      }

      final near = go(30)!;
      expect(near.metres, closeTo(72, 3)); // 30 + 12 + 30 via the signals
      expect(near.maneuvers.where((m) => m.type == ManeuverType.cross).single.crossing,
          WalkCrossing.signals);
      final far = go(300)!;
      expect(far.metres, closeTo(12, 2)); // not worth 600 m: takes the unmarked one
      expect(far.maneuvers.where((m) => m.type == ManeuverType.cross).single.crossing,
          WalkCrossing.unmarked);
    });

    test('steps are penalised but used when the alternative is long', () {
      WalkRoute? go(double detour) {
        final b = _B();
        final a = b.node(0, 0), c = b.node(0, 20), mid = b.node(0 + detour / 2, 10);
        b.edge(a, c, _steps);
        b.edge(a, mid, _path, via: [(detour / 4, 5)]);
        b.edge(mid, c, _path, via: [(detour / 4, 15)]);
        return WalkRouter(b.build()).route(latOf(0), lonOf(0), latOf(20), lonOf(0));
      }

      // steps cost 3 x 20 = 60: a 40 m detour wins, a 90 m one does not.
      final short = go(36)!;
      expect(short.maneuvers.any((m) => m.type == ManeuverType.steps), isFalse);
      final long = go(90)!;
      expect(long.maneuvers.any((m) => m.type == ManeuverType.steps), isTrue);
      expect(long.metres, closeTo(20, 1)); // true metres, not cost
    });

    test('snaps to the middle of an edge, not to its nodes', () {
      final b = _B();
      final n0 = b.node(0, 0), n1 = b.node(200, 0);
      b.edge(n0, n1, _path, name: 'Via Lunga');
      final r = WalkRouter(b.build());
      final route = r.route(latOf(10), lonOf(60), latOf(-10), lonOf(140))!;
      expect(route.metres, closeTo(10 + 80 + 10, 2));
      final ends = route.polyline.first;
      expect(ends, [lonOf(60), latOf(10)]);
      // No vertex at either node: the path enters and leaves mid-edge.
      for (final p in route.polyline) {
        expect((p[0] - lonOf(0)).abs() > 1e-5 || (p[1] - latOf(0)).abs() > 1e-5, isTrue);
      }
      expect(r.snap(latOf(500), lonOf(60)), isNull); // outside coverage
    });

    test('maneuvers: start, turn with street name, cross, steps, arrive', () {
      final b = _B();
      final a = b.node(0, 0), c = b.node(0, 100), d = b.node(100, 100);
      final e = b.node(112, 100), f = b.node(112, 130), g = b.node(200, 130);
      b.edge(a, c, _path, name: 'Via Nord');
      b.edge(c, d, _path, name: 'Via Est'); // right turn at c
      b.edge(d, e, _cross(WalkCrossing.zebra), name: 'Corso Grande');
      b.edge(e, f, _steps, name: 'Scalinata');
      b.edge(f, g, _path, name: 'Via Fine'); // right turn after the steps
      final route = WalkRouter(b.build()).route(latOf(0), lonOf(0), latOf(130), lonOf(200))!;
      final types = route.maneuvers.map((m) => m.type).toList();
      expect(types.first, ManeuverType.start);
      expect(types.last, ManeuverType.arrive);
      expect(types, containsAllInOrder([
        ManeuverType.start,
        ManeuverType.right,
        ManeuverType.cross,
        ManeuverType.steps,
        ManeuverType.arrive,
      ]));
      final turn = route.maneuvers.firstWhere((m) => m.type == ManeuverType.right);
      expect(turn.street, 'Via Est');
      final cross = route.maneuvers.firstWhere((m) => m.type == ManeuverType.cross);
      expect(cross.street, 'Corso Grande');
      expect(cross.crossing, WalkCrossing.zebra);
      // indices ascend, distances add up to the whole route
      var last = -1;
      var sum = 0.0;
      for (final m in route.maneuvers) {
        expect(m.pointIndex, greaterThanOrEqualTo(last));
        last = m.pointIndex;
        sum += m.metres;
      }
      expect(sum, closeTo(route.metres, 1));
      expect(route.seconds, (route.metres / walkSpeedMetresPerSecond).round());
    });

    test('re-route from an arbitrary position reaches the same target, shorter', () {
      final b = _B();
      final a = b.node(0, 0), c = b.node(0, 200), d = b.node(200, 200), e = b.node(200, 0);
      b.edge(a, c, _path);
      b.edge(c, d, _path);
      b.edge(d, e, _path);
      b.edge(a, e, _path); // the alternative, straight along the bottom
      final r = WalkRouter(b.build());
      final original = r.route(latOf(0), lonOf(0), latOf(0), lonOf(200))!;
      expect(original.metres, closeTo(200, 2));
      // The walker strayed to the north-west corner.
      final again = r.reroute(latOf(150), lonOf(5), original)!;
      expect(again.endLat, closeTo(original.endLat, 1e-6));
      expect(again.endLon, closeTo(original.endLon, 1e-6));
      expect(again.polyline.first, [lonOf(5), latOf(150)]);
      expect(again.metres, closeTo(150 + 200 + 5, 12)); // back down the west edge, then east
    });
  });

  group('builder rules', () {
    // A primary road W-E, a residential street N-S crossing it, motorway apart.
    Map<String, dynamic> osm({String? junctionTag, bool motorway = false}) {
      const lat = 45.0, lon = 7.6;
      Map<String, dynamic> n(int id, double dx, double dy, [Map<String, String>? tags]) => {
            'type': 'node',
            'id': id,
            'lat': lat + dy / 111195,
            'lon': lon + dx / (111195 * 0.7071),
            'tags': ?tags,
          };
      Map<String, dynamic> w(int id, List<int> nodes, Map<String, String> tags) =>
          {'type': 'way', 'id': id, 'nodes': nodes, 'tags': tags};
      return {
        'osm3s': {'timestamp_osm_base': '2026-09-01T00:00:00Z'},
        'elements': [
          n(1, -300, 0), n(2, -150, 0), n(3, 0, 0, junctionTag == null ? null : {'highway': junctionTag}),
          n(4, 150, 0), n(5, 300, 0),
          n(6, 0, -300), n(7, 0, -150), n(8, 0, 150), n(9, 0, 300),
          n(20, -300, 400), n(21, 300, 400), n(22, -300, 420), n(23, 300, 420),
          w(100, [1, 2, 3, 4, 5], {'highway': 'primary', 'name': 'Corso Grande', 'sidewalk': 'both'}),
          w(101, [6, 7, 3, 8, 9], {'highway': 'residential', 'name': 'Via Piccola'}),
          if (motorway) ...[
            // footways on each side of a motorway, no shared nodes
            w(102, [20, 21], {'highway': 'footway'}),
            w(103, [22, 23], {'highway': 'footway'}),
            w(104, [20, 22], {'highway': 'motorway', 'name': 'A4'}),
          ],
        ],
      };
    }

    WalkGraph build(Map<String, dynamic> json) {
      final data = OsmData()..addOverpass(json);
      return buildWalkGraph(data, south: 44.99, west: 7.59, north: 45.02, east: 7.62,
          minComponentEdges: 0);
    }

    test('an untagged junction of a busy road is an unmarked crossing edge', () {
      final g = build(osm());
      final types = <int>[
        for (var e = 0; e < g.edgeCount; e++)
          if (WalkFlags.kind(g.edgeFlags[e]) == WalkKind.crossing) WalkFlags.sub(g.edgeFlags[e])
      ];
      expect(types, isNotEmpty);
      expect(types.every((t) => t == WalkCrossing.unmarked), isTrue);
      final names = {
        for (var e = 0; e < g.edgeCount; e++)
          if (WalkFlags.kind(g.edgeFlags[e]) == WalkKind.crossing && g.edgeName[e] >= 0)
            g.names[g.edgeName[e]]
      };
      expect(names, contains('Corso Grande'));
    });

    test('signals on the junction make it a signalised crossing, and cheaper', () {
      final signalled = build(osm(junctionTag: 'traffic_signals'));
      final untagged = build(osm());
      double crossCost(WalkGraph g) {
        for (var e = 0; e < g.edgeCount; e++) {
          if (WalkFlags.kind(g.edgeFlags[e]) == WalkKind.crossing) {
            return walkEdgeCost(g.edgeFlags[e], g.edgeLen[e]);
          }
        }
        return double.nan;
      }

      expect(crossCost(signalled), lessThan(crossCost(untagged)));
      // North to south along the minor street crosses once, and the route sees it.
      final r = WalkRouter(signalled);
      final route = r.route(45.0 + 200 / 111195, 7.6, 45.0 - 200 / 111195, 7.6)!;
      expect(route.maneuvers.where((m) => m.type == ManeuverType.cross), hasLength(1));
      expect(route.metres, greaterThan(395));
      expect(route.metres, lessThan(470));
    });

    test('a motorway without foot=yes is never crossed or walked', () {
      final g = build(osm(motorway: true));
      final r = WalkRouter(g);
      const lat = 45.0, lon = 7.6;
      // footway 102 (north) to footway 103 (south of it by 20 m): no way across.
      final route = r.route(lat + 400 / 111195, lon - 100 / 78620, lat + 420 / 111195, lon - 100 / 78620);
      expect(route, isNull);
      expect(classifyWay({'highway': 'motorway'}), isNull);
      expect(classifyWay({'highway': 'motorway', 'foot': 'yes'}), isNotNull);
    });

    test('exclusions and the general tag rules', () {
      expect(classifyWay({'highway': 'footway', 'foot': 'no'}), isNull);
      expect(classifyWay({'highway': 'service', 'access': 'private'}), isNull);
      expect(classifyWay({'highway': 'service', 'access': 'private', 'foot': 'yes'}), isNotNull);
      expect(classifyWay({'highway': 'construction'}), isNull);
      expect(classifyWay({'highway': 'residential', 'construction': 'yes'}), isNull);
      expect(classifyWay({'highway': 'cycleway'}), isNull);
      expect(classifyWay({'highway': 'cycleway', 'foot': 'designated'}), isNotNull);
      expect(classifyWay({'highway': 'steps'})!.kind, WalkKind.steps);
      expect(classifyWay({'highway': 'primary'})!.sided, isTrue);
      expect(classifyWay({'highway': 'residential'})!.sided, isFalse);
      expect(classifyWay({'highway': 'footway', 'tunnel': 'building_passage'})!.covered, isTrue);
      expect(classifyWay({'highway': 'footway', 'covered': 'arcade'})!.covered, isTrue);
      final zebra = classifyWay({'highway': 'footway', 'footway': 'crossing', 'crossing': 'zebra'})!;
      expect((zebra.kind, zebra.sub), (WalkKind.crossing, WalkCrossing.zebra));
      final sig = classifyWay({'highway': 'footway', 'footway': 'crossing', 'crossing': 'traffic_signals'})!;
      expect(sig.sub, WalkCrossing.signals);
      final left = classifyWay({'highway': 'secondary', 'sidewalk': 'left'})!;
      expect((left.left, left.right), (1, 2));
      expect(nodeCrossing({'highway': 'crossing', 'crossing': 'unmarked'}), WalkCrossing.unmarked);
      expect(nodeCrossing({'highway': 'traffic_signals'}), WalkCrossing.signals);
      expect(nodeCrossing({'highway': 'bus_stop'}), -1);
    });
  });

  group('format', () {
    WalkGraph tiny() {
      final b = _B();
      final a = b.node(0, 0), c = b.node(100, 0), d = b.node(100, 80);
      b.edge(a, c, _path, name: 'Via È', via: [(50, 3)]);
      b.edge(c, d, _cross(WalkCrossing.zebra));
      return b.build();
    }

    test('round trip, header fields and deterministic bytes', () {
      final g = tiny();
      final bytes = g.encode();
      expect(bytes, g.encode());
      final back = WalkGraph.decode(bytes);
      expect(back.nodeCount, g.nodeCount);
      expect(back.edgeCount, g.edgeCount);
      expect(back.names, ['Via È']);
      expect(back.edgeLen[0], closeTo(g.edgeLen[0], 1e-3));
      expect(back.header.format, walkGraphFormat);
      expect(back.header.osmTime, 1700000000);
      expect(back.header.covers(latOf(0), lonOf(0)), isTrue);
      expect(back.header.sha256Hex, hasLength(64));
    });

    test('bad hash, truncation, wrong magic and newer format are rejected', () {
      final bytes = tiny().encode();
      final flipped = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 0xff;
      expect(() => WalkGraph.decode(flipped),
          throwsA(isA<WalkFormatException>().having((e) => e.incompatible, 'incompatible', false)));
      expect(() => WalkGraph.decode(Uint8List.sublistView(bytes, 0, bytes.length - 5)),
          throwsA(isA<WalkFormatException>()));
      final magic = Uint8List.fromList(bytes)..[0] = 0;
      expect(() => WalkGraph.decode(magic), throwsA(isA<WalkFormatException>()));
      final newer = Uint8List.fromList(bytes)..[4] = walkGraphFormat + 1;
      expect(() => WalkGraph.decode(newer),
          throwsA(isA<WalkFormatException>().having((e) => e.incompatible, 'incompatible', true)));
    });
  });
}
