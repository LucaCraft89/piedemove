import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/distance.dart';
import 'package:piedemove/geo/line_merge.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/map_match.dart';
import 'package:piedemove/geo/pattern_snap.dart';
import 'package:piedemove/geo/road_graph.dart';

OsmWay way(int id, List<List<double>> points,
        [Map<String, String> tags = const {'highway': 'residential'}]) =>
    OsmWay(
      id,
      {...tags},
      Float64List.fromList([for (final p in points) p[0]]),
      Float64List.fromList([for (final p in points) p[1]]),
    );

/// A straight run of points from (lat0, lon0) to (lat1, lon1), every `step`.
List<List<double>> run(double lat0, double lon0, double lat1, double lon1,
    {int n = 10}) =>
    [
      for (var i = 0; i <= n; i++)
        [lat0 + (lat1 - lat0) * i / n, lon0 + (lon1 - lon0) * i / n],
    ];

ShapePolyline shape(List<List<double>> pts) => ShapePolyline(
      Float64List.fromList([for (final p in pts) p[0]]),
      Float64List.fromList([for (final p in pts) p[1]]),
    );

SnappedPattern match(RoadGraph g, List<List<double>> stops,
        {ShapePolyline? shape}) =>
    PatternSnapper(g).snap(
      pattern: 0,
      stopLat: Float64List.fromList([for (final s in stops) s[0]]),
      stopLon: Float64List.fromList([for (final s in stops) s[1]]),
      shape: shape,
    );

Set<int> waysOf(SnappedPattern p) => {for (final w in p.vertexWay) if (w >= 0) w};

double segMetres(SnappedPattern p, int i) => haversineMetres(
    p.vertexLat[i] / 1e6, p.vertexLon[i] / 1e6,
    p.vertexLat[i + 1] / 1e6, p.vertexLon[i + 1] / 1e6);

void main() {
  test('shape on a bent road: one continuous path on the ways, stops in order',
      () {
    final g = RoadGraph.build([
      way(1, run(45.000, 7.600, 45.000, 7.610)),
      way(2, run(45.000, 7.610, 45.010, 7.610)),
    ], GraphMode.bus);
    // The shape runs ~6 m beside the road, as a real shape does.
    final s = shape([
      ...run(45.00005, 7.600, 45.00005, 7.60995),
      ...run(45.00005, 7.60995, 45.010, 7.60995),
    ]);
    final p = match(
        g,
        [
          [45.0000, 7.6005],
          [45.0000, 7.6050],
          [45.0050, 7.6100],
          [45.0095, 7.6100],
        ],
        shape: s);
    expect(p.hopApprox.every((f) => f == 0), isTrue);
    expect(waysOf(p), {1, 2});
    for (var i = 1; i < p.stopVertex.length; i++) {
      expect(p.stopVertex[i], greaterThanOrEqualTo(p.stopVertex[i - 1]));
    }
    // Every vertex lies on a road: within a metre of one of the two ways.
    for (var i = 0; i < p.vertexCount; i++) {
      final lat = p.vertexLat[i] / 1e6, lon = p.vertexLon[i] / 1e6;
      final onWay1 = (lat - 45.0).abs() * 111320 < 1 && lon >= 7.5999 && lon <= 7.6101;
      final onWay2 = (lon - 7.610).abs() * 78700 < 1 && lat >= 44.9999 && lat <= 45.0101;
      expect(onWay1 || onWay2, isTrue, reason: 'vertex $i off the road');
    }
  });

  test('oneway pair: each direction takes its own carriageway', () {
    final g = RoadGraph.build([
      way(10, run(45.000, 7.600, 45.000, 7.602, n: 4),
          {'highway': 'primary', 'oneway': 'yes'}),
      way(11, run(45.0003, 7.602, 45.0003, 7.600, n: 4),
          {'highway': 'primary', 'oneway': 'yes'}),
      way(12, run(45.000, 7.602, 45.0003, 7.602, n: 2)),
      way(13, run(45.0003, 7.600, 45.000, 7.600, n: 2)),
    ], GraphMode.bus);
    // Both directions share the road's centre line, between the carriageways.
    final east = match(g, [
      [45.0000, 7.6002],
      [45.0000, 7.6018],
    ], shape: shape(run(45.00012, 7.600, 45.00012, 7.602, n: 10)));
    final west = match(g, [
      [45.0003, 7.6018],
      [45.0003, 7.6002],
    ], shape: shape(run(45.00018, 7.602, 45.00018, 7.600, n: 10)));
    expect(east.hopApprox.first, 0);
    expect(west.hopApprox.first, 0);
    expect(waysOf(east), contains(10));
    expect(waysOf(east), isNot(contains(11)));
    expect(waysOf(west), contains(11));
    expect(waysOf(west), isNot(contains(10)));
  });

  test('loop route: a stop visited twice lands on the right pass', () {
    final g = RoadGraph.build([
      way(20, [
        ...run(45.000, 7.600, 45.000, 7.602, n: 4),
        ...run(45.000, 7.602, 45.002, 7.602, n: 4).skip(1),
        ...run(45.002, 7.602, 45.002, 7.600, n: 4).skip(1),
        ...run(45.002, 7.600, 45.000, 7.600, n: 4).skip(1),
      ], {'highway': 'residential', 'oneway': 'yes'}),
    ], GraphMode.bus);
    final s = shape([
      ...run(45.00003, 7.5999, 45.00003, 7.602, n: 8),
      ...run(45.00003, 7.602, 45.002, 7.602, n: 8).skip(1),
      ...run(45.002, 7.602, 45.002, 7.600, n: 8).skip(1),
      ...run(45.002, 7.600, 45.00003, 7.600, n: 8).skip(1),
      [45.00003, 7.6005],
    ]);
    final p = match(
        g,
        [
          [45.0000, 7.6005], // south side, first pass
          [45.0010, 7.6020], // east side
          [45.0020, 7.6010], // north side
          [45.0000, 7.6005], // south side again, last pass
        ],
        shape: s);
    for (var i = 1; i < p.stopVertex.length; i++) {
      expect(p.stopVertex[i], greaterThan(p.stopVertex[i - 1]),
          reason: 'stop vertices must advance along the pattern');
    }
    expect(p.stopVertex.last, greaterThan(p.vertexCount * 0.8));
  });

  test('a shape against a one-way street is matched on it, not dotted', () {
    final g = RoadGraph.build([
      way(30, run(45.000, 7.600, 45.000, 7.604, n: 8),
          {'highway': 'residential', 'oneway': 'yes'}),
    ], GraphMode.bus);
    final p = match(g, [
      [45.0000, 7.6035],
      [45.0000, 7.6005],
    ], shape: shape(run(45.00003, 7.6038, 45.00003, 7.6002, n: 8)));
    expect(p.hopApprox.first, 0, reason: 'contraflow is allowed at a penalty');
    expect(waysOf(p), {30});
  });

  test('no road under the shape: that stretch follows the shape, dotted', () {
    // Two road pieces with ~350 m of nothing between them.
    final g = RoadGraph.build([
      way(40, run(45.000, 7.600, 45.000, 7.604, n: 8)),
      way(41, run(45.000, 7.609, 45.000, 7.613, n: 8)),
    ], GraphMode.bus);
    final s = shape(run(45.00003, 7.600, 45.00003, 7.613, n: 26));
    final p = match(g, [
      [45.0000, 7.601],
      [45.0000, 7.6125],
    ], shape: s);
    expect(p.hopApprox.single, 1);
    expect(waysOf(p), {40, 41});
    // Dotted vertices trace the shape: no single long chord across the gap.
    var longest = 0.0;
    for (var i = 0; i + 1 < p.vertexCount; i++) {
      if (p.vertexWay[i + 1] < 0) longest = math.max(longest, segMetres(p, i));
    }
    expect(longest, lessThan(20));
  });

  test('a pattern with no shape is routed stop to stop', () {
    final g = RoadGraph.build([
      way(50, run(45.000, 7.600, 45.000, 7.610)),
      way(51, run(45.000, 7.610, 45.008, 7.610)),
    ], GraphMode.bus);
    final p = match(g, [
      [45.0000, 7.6010],
      [45.0000, 7.6090],
      [45.0070, 7.6100],
    ]);
    expect(p.hopApprox.every((f) => f == 0), isTrue);
    expect(waysOf(p), {50, 51});
  });

  test('a shape-only pattern keeps its shape; without one it is marked', () {
    final s = shape(run(45.0, 7.60, 45.0, 7.61, n: 5));
    final withShape = snapShapeOnly(
        1, [45.0, 45.0], [7.601, 7.609], s);
    expect(withShape.hopApprox.single, 0);
    expect(withShape.vertexEdge!.contains(edgeApprox), isFalse);
    final guessed = snapShapeOnly(2, [45.0, 45.0], [7.601, 7.609], null);
    expect(guessed.hopApprox.single, 1);
  });

  test('stop placement never moves backwards on an out-and-back path', () {
    // East then back west along the same line: stop B sits at the far end.
    final lat = <double>[45.0, 45.0, 45.0];
    final lon = <double>[7.600, 7.604, 7.600];
    final pos = placeStops(lat, lon, [45.0, 45.0, 45.0], [7.6001, 7.604, 7.6002]);
    expect(pos[0], lessThan(pos[1]));
    expect(pos[1], lessThanOrEqualTo(pos[2]));
    expect(pos[2], greaterThan(pos[1]), reason: 'last stop is on the way back');
  });

  test('oneway:bus=no reopens the reverse direction for buses only', () {
    final w = way(60, run(45.0, 7.600, 45.0, 7.601, n: 1),
        {'highway': 'residential', 'oneway': 'yes', 'oneway:bus': 'no'});
    expect(wayDirections(w, GraphMode.bus), (true, true));
    expect(wayDirections(w, GraphMode.tram), (true, false));
  });

  test('lines.bin round-trips and rejects another feed', () {
    final g = RoadGraph.build([way(70, run(45.0, 7.600, 45.0, 7.604, n: 8))],
        GraphMode.bus);
    final net = LineNetwork('feed-a', [
      match(
          g,
          [
            [45.0000, 7.6005],
            [45.0000, 7.6035],
          ],
          shape: shape(run(45.00003, 7.600, 45.00003, 7.604, n: 8))),
    ], signatures: ['2|3|A,B']);
    final bytes = encodeLines(net);
    final back = decodeLines(bytes, feedVersion: 'feed-a');
    expect(back, isNotNull);
    expect(back![0]!.vertexWay, net.patterns.first.vertexWay);
    expect(back[0]!.stopVertex, net.patterns.first.stopVertex);
    expect(decodeLines(bytes, feedVersion: 'feed-b'), isNull);
    expect(back.signatures, ['2|3|A,B']);
  });

  group('merge by graph segment identity', () {
    void add(LineMerger m, int mode, String route, int from, int to) => m.add(
          mode: mode,
          route: route,
          from: from,
          to: to,
          fromLat: 45.0 + from * 0.001,
          fromLon: 7.0,
          toLat: 45.0 + to * 0.001,
          toLon: 7.0,
        );

    test('three routes and both directions share one segment; width capped', () {
      final m = LineMerger();
      for (final r in ['4', '10', '55']) {
        add(m, RouteType.bus, r, 1, 2);
      }
      add(m, RouteType.bus, '4', 2, 1); // the way back: same physical segment
      add(m, RouteType.tram, '13', 1, 2); // another mode: its own segment
      final segs = m.segments;
      expect(segs, hasLength(2));
      final bus = segs.firstWhere((s) => s.mode == RouteType.bus);
      expect(bus.routes, {'4', '10', '55'});
      expect(bus.oneDirection, isFalse);
      expect(mergedWidth(1), 4.0);
      expect(mergedWidth(3), closeTo(4.0 * 1.8, 1e-9));
      expect(mergedWidth(20), 12.0);
    });

    test('a route set change breaks the chain; the rest chains through', () {
      final m = LineMerger();
      for (var i = 0; i < 4; i++) {
        add(m, RouteType.bus, '5', i, i + 1);
      }
      add(m, RouteType.bus, '9', 1, 2); // 9 rides only the second segment
      final chains = chainSegments(m.segments);
      // 5 alone: segment 0-1, and 2-3-4; 5+9: segment 1-2.
      expect(chains, hasLength(3));
      final shared = chains.firstWhere((c) => c.routes.length == 2);
      expect(shared.pts, hasLength(4));
      final long = chains.firstWhere((c) => c.routes.length == 1 && c.pts.length > 4);
      expect(long.pts, hasLength(6));
      expect(long.oneDirection, isTrue);
    });

    test('a fork ends the chain at the fork node', () {
      final m = LineMerger();
      add(m, RouteType.bus, '5', 1, 2);
      add(m, RouteType.bus, '5', 2, 3);
      add(m, RouteType.bus, '5', 2, 4);
      expect(chainSegments(m.segments), hasLength(3));
    });

    test('two-way segments chain whatever their stored orientation', () {
      final m = LineMerger();
      // Travelled out along 1-2-3 and back along 3-2-1.
      for (final (a, b) in [(1, 2), (2, 3), (3, 2), (2, 1)]) {
        add(m, RouteType.bus, '5', a, b);
      }
      final chains = chainSegments(m.segments);
      expect(chains, hasLength(1));
      expect(chains.single.pts, hasLength(6));
      expect(chains.single.oneDirection, isFalse);
    });
  });
}
