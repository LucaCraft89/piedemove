import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/line_build.dart';
import 'package:piedemove/geo/ambient.dart';
import 'package:piedemove/geo/line_merge.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/pattern_snap.dart';
import 'package:piedemove/geo/road_graph.dart';

OsmWay way(int id, List<List<double>> points, [Map<String, String> tags = const {'highway': 'residential'}]) =>
    OsmWay(
      id,
      {...tags},
      Float64List.fromList([for (final p in points) p[0]]),
      Float64List.fromList([for (final p in points) p[1]]),
    );

SnappedPattern snapStops(RoadGraph g, List<List<double>> stops) =>
    PatternSnapper(g).snap(
      pattern: 0,
      stopLat: Float64List.fromList([for (final s in stops) s[0]]),
      stopLon: Float64List.fromList([for (final s in stops) s[1]]),
    );

Set<int> waysOf(SnappedPattern p) =>
    {for (final w in p.vertexWay) if (w >= 0) w};

void main() {
  moreLineTests();

  test('two-way junction: a hop routes through the shared node', () {
    final g = RoadGraph.build([
      way(1, [
        [45.000, 7.600],
        [45.000, 7.601],
        [45.000, 7.602],
      ]),
      way(2, [
        [45.000, 7.601],
        [45.001, 7.601],
      ]),
    ], GraphMode.bus);

    // The junction coordinate is shared exactly, so it is one node.
    expect(g.nodeCount, 4);

    final p = snapStops(g, [
      [45.0000, 7.6001],
      [45.0010, 7.6010],
    ]);
    expect(p.hopApprox.first, 0, reason: 'hop must route, not chord');
    expect(waysOf(p), {1, 2});
    expect(p.stopVertex.last, p.vertexCount - 1);
  });

  test('oneway pair: the two directions take different edges', () {
    final ways = [
      way(10, [
        [45.000, 7.600],
        [45.000, 7.602],
      ], {'highway': 'primary', 'oneway': 'yes'}),
      way(11, [
        [45.0005, 7.602],
        [45.0005, 7.600],
      ], {'highway': 'primary', 'oneway': 'yes'}),
      way(12, [
        [45.000, 7.602],
        [45.0005, 7.602],
      ]),
      way(13, [
        [45.0005, 7.600],
        [45.000, 7.600],
      ]),
    ];
    final g = RoadGraph.build(ways, GraphMode.bus);

    final east = snapStops(g, [
      [45.0000, 7.6002],
      [45.0000, 7.6018],
    ]);
    final west = snapStops(g, [
      [45.0005, 7.6018],
      [45.0005, 7.6002],
    ]);
    expect(east.hopApprox.first, 0);
    expect(west.hopApprox.first, 0);
    expect(waysOf(east), {10});
    expect(waysOf(west), {11});
  });

  test('loop route: a stop visited twice slices on the right pass', () {
    // One-way square, counter-clockwise, closed at the start coordinate.
    final g = RoadGraph.build([
      way(20, [
        [45.000, 7.600],
        [45.000, 7.602],
        [45.002, 7.602],
        [45.002, 7.600],
        [45.000, 7.600],
      ], {'highway': 'residential', 'oneway': 'yes'}),
    ], GraphMode.bus);

    final p = snapStops(g, [
      [45.0000, 7.6005], // south side, first pass
      [45.0010, 7.6020], // east side
      [45.0020, 7.6010], // north side
      [45.0000, 7.6005], // south side again, last pass
    ]);
    expect(p.hopApprox.every((f) => f == 0), isTrue);
    for (var i = 1; i < p.stopVertex.length; i++) {
      expect(p.stopVertex[i], greaterThan(p.stopVertex[i - 1]),
          reason: 'stop vertices must advance along the pattern');
    }
    expect(p.stopVertex.last, p.vertexCount - 1);
  });

  test('oneway:bus=no reopens the reverse direction for buses only', () {
    final w = way(30, [
      [45.000, 7.600],
      [45.000, 7.601],
    ], {'highway': 'residential', 'oneway': 'yes', 'oneway:bus': 'no'});
    expect(wayDirections(w, GraphMode.bus), (true, true));
    expect(wayDirections(w, GraphMode.tram), (true, false));
  });

  test('lines.bin round-trips and rejects another feed', () {
    final g = RoadGraph.build([
      way(40, [
        [45.000, 7.600],
        [45.000, 7.602],
      ]),
    ], GraphMode.bus);
    final net = LineNetwork('feed-a', [
      snapStops(g, [
        [45.0000, 7.6002],
        [45.0000, 7.6018],
      ]),
    ]);
    final bytes = encodeLines(net);
    final back = decodeLines(bytes, feedVersion: 'feed-a');
    expect(back, isNotNull);
    expect(back![0]!.vertexWay, net.patterns.first.vertexWay);
    expect(back[0]!.stopVertex, net.patterns.first.stopVertex);
    expect(decodeLines(bytes, feedVersion: 'feed-b'), isNull);
  });

  test('a pattern without a graph falls back to its stop chain', () {
    final p = shapeChainPattern(
      7,
      Float64List.fromList([45.0, 45.01]),
      Float64List.fromList([7.6, 7.61]),
    );
    expect(p.vertexCount, 2);
    expect(p.stopVertex, [0, 1]);
    expect(p.vertexWay.every((w) => w == -1), isTrue);
  });

  test('same-way merge: three routes give n = 3, width capped at 3x', () {
    final m = LineMerger();
    for (final route in ['4', '10', '55']) {
      m.add(
        mode: RouteType.bus,
        route: route,
        way: 77,
        aLat: 45.07,
        aLon: 7.66,
        bLat: 45.071,
        bLon: 7.661,
      );
    }
    // The reverse direction of the same way collapses into the same segment.
    m.add(
      mode: RouteType.bus,
      route: '4',
      way: 77,
      aLat: 45.071,
      aLon: 7.661,
      bLat: 45.07,
      bLon: 7.66,
    );
    // A tram on the same street is another way: its own segment.
    m.add(
      mode: RouteType.tram,
      route: '13',
      way: 78,
      aLat: 45.07,
      aLon: 7.66,
      bLat: 45.071,
      bLon: 7.661,
    );
    // A chord (way < 0) is not part of the ambient network.
    m.add(
      mode: RouteType.bus,
      route: '9',
      way: -1,
      aLat: 45.07,
      aLon: 7.66,
      bLat: 45.071,
      bLon: 7.661,
    );

    final segs = m.segments;
    expect(segs.length, 2);
    final bus = segs.firstWhere((s) => s.mode == RouteType.bus);
    expect(bus.routes.length, 3);
    expect(bus.oneDirection, isFalse);
    expect(mergedWidth(1), 4.0);
    expect(mergedWidth(3), closeTo(4.0 * 1.8, 1e-9));
    expect(mergedWidth(20), 12.0); // capped at 3x
  });

}

MergedSeg seg(int mode, double aLat, double aLon, double bLat, double bLon,
    String route) {
  final m = LineMerger()
    ..add(
      mode: mode,
      route: route,
      way: mode,
      aLat: aLat,
      aLon: aLon,
      bLat: bLat,
      bLon: bLon,
    );
  return m.segments.single;
}

void moreLineTests() {
  test('consecutive segments of the same routes chain into one line', () {
    final m = LineMerger();
    for (var i = 0; i < 3; i++) {
      m.add(
        mode: RouteType.bus,
        route: '5',
        way: 1,
        aLat: 45.0 + i * 0.001,
        aLon: 7.0,
        bLat: 45.0 + (i + 1) * 0.001,
        bLon: 7.0,
      );
    }
    final chains = chainSegments(m.segments);
    expect(chains, hasLength(1));
    expect(chains.single.pts, hasLength(8)); // 4 points, lat/lon each
    expect(chains.single.oneDirection, isTrue);
  });

  test('a shared bus/tram street pushes the two apart, not onto each other',
      () {
    final bus = seg(RouteType.bus, 45.0, 7.0, 45.0, 7.001, '55');
    final tram = seg(RouteType.tram, 45.00002, 7.0, 45.00002, 7.001, '4');
    final before = (bus.aLat - tram.aLat).abs();
    offsetSharedBusTram([bus, tram]);
    final after = (bus.aLat - tram.aLat).abs();
    expect(after, greaterThan(before));
    expect(after * 111320, closeTo(2 * sharedShiftMetres, 2.5));
  });

  test('a bus street with no tram beside it is not offset', () {
    final bus = seg(RouteType.bus, 45.0, 7.0, 45.0, 7.001, '55');
    final tram = seg(RouteType.tram, 45.01, 7.0, 45.01, 7.001, '4');
    final lat = bus.aLat;
    offsetSharedBusTram([bus, tram]);
    expect(bus.aLat, lat);
  });
}
