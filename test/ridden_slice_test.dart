/// Ridden part = pattern slice between the stored stop vertices (lesson 1),
/// even when the path passes the boarding stop's coordinate twice; widths obey
/// ridden >= 2x context; ends and mids are sized by the constants.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/pattern_snap.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/map/line_features.dart';
import 'package:piedemove/ui/map/map_style.dart';

import 'support/synthetic.dart';

void main() {
  test('ridden slice follows stored stop vertices, not nearest point', () {
    final ix = syntheticIndex(
      stops: [('A', 'A', 45.0, 7.6), ('B', 'B', 45.01, 7.6), ('C', 'C', 45.02, 7.6)],
      patterns: [('9', RouteType.bus, ['A', 'B', 'C'], [[0, 60]])],
    );
    // Vertex 1 and vertex 6 are the same point (a loop through B's position);
    // B's stored vertex is 6, so the ride B->C must start at 6, not at 1.
    final lat = [0, 10, 20, 30, 40, 50, 10, 60, 70, 80]
        .map((v) => 45000000 + v * 100).toList();
    final lon = List.filled(10, 7600000);
    final geom = SnappedPattern(
      pattern: 0,
      vertexLat: Int32List.fromList(lat),
      vertexLon: Int32List.fromList(lon),
      vertexWay: Int64List(10),
      vertexDir: Uint8List(10),
      stopVertex: Int32List.fromList([0, 6, 9]),
      stopLat: Int32List(3),
      stopLon: Int32List(3),
      hopApprox: Uint8List(2),
    );
    final net = LineNetwork('t', [geom]);
    const opt = RideOption(
        routeShortName: '9', routeType: RouteType.bus, pattern: 0, trip: 0,
        departure: 0, arrival: 60);
    final j = Journey(const [
      Leg(kind: LegKind.ride, fromStop: 1, toStop: 2, departure: 0, arrival: 60,
          options: [opt]),
    ], DateTime(2026));
    final feats = (journeyFocusLines(ix, net, j)['features'] as List)
        .cast<Map<String, dynamic>>();
    final ridden = feats.singleWhere((f) => f['properties']['kind'] == kindRidden);
    final ctx = feats.singleWhere((f) => f['properties']['kind'] == kindContext);
    expect((ridden['geometry']['coordinates'] as List).length, 4); // vertices 6..9
    expect((ctx['geometry']['coordinates'] as List).length, 10);
  });

  test('ridden is at least 2x context at every zoom stop', () {
    for (var i = 0; i < ambientBaseWidths.length; i++) {
      expect(ambientBaseWidths[i].$1, contextBaseWidths[i].$1);
      expect(ambientBaseWidths[i].$2 / contextBaseWidths[i].$2,
          greaterThanOrEqualTo(riddenToContextMin));
    }
    expect(endDot, greaterThan(midDot));
  });
}
