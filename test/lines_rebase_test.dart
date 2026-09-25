// Line geometry follows GTT across exports (audit 2026-09): matched by
// pattern signature, not pattern number; what has no geometry is drawn
// through its stops, dotted and marked approximate.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/lines_rebase.dart';
import 'package:piedemove/geo/pattern_snap.dart';
import 'package:piedemove/ui/map/line_features.dart';

import 'support/synthetic.dart';

const _stops = [
  ('A', 'ALFA', 45.00, 7.60),
  ('B', 'BRAVO', 45.01, 7.60),
  ('C', 'CHARLIE', 45.02, 7.60),
  ('D', 'DELTA', 45.00, 7.62),
  ('E', 'ECHO', 45.01, 7.62),
];

/// A matched-looking geometry for [p]: one extra vertex per hop.
SnappedPattern _geom(TransitIndex ix, int p) {
  final n = ix.patternLength(p);
  final lat = <int>[], lon = <int>[], stopVertex = <int>[];
  for (var i = 0; i < n; i++) {
    final s = ix.patternStopAt(p, i);
    stopVertex.add(lat.length);
    lat.add(microdeg(ix.stopLat[s]));
    lon.add(microdeg(ix.stopLon[s]));
    if (i < n - 1) {
      lat.add(microdeg(ix.stopLat[s]) + 10);
      lon.add(microdeg(ix.stopLon[s]) + 500); // a bend: not a straight chord
    }
  }
  return SnappedPattern(
    pattern: p,
    vertexLat: Int32List.fromList(lat),
    vertexLon: Int32List.fromList(lon),
    vertexWay: Int64List(lat.length),
    vertexDir: Uint8List(lat.length),
    stopVertex: Int32List.fromList(stopVertex),
    stopLat: Int32List.fromList([for (final v in stopVertex) lat[v]]),
    stopLon: Int32List.fromList([for (final v in stopVertex) lon[v]]),
    hopApprox: Uint8List(n - 1),
  );
}

LineNetwork _built(TransitIndex ix) {
  final pats = [for (var p = 0; p < ix.patternCount; p++) _geom(ix, p)];
  return LineNetwork(ix.feedVersion, pats,
      signatures: [for (final g in pats) patternSignature(ix, g.pattern)]);
}

void main() {
  // The export the geometry was built from.
  final old = syntheticIndex(stops: _stops, patterns: [
    ('1', 3, ['A', 'B', 'C'], [
      [0, 60, 120],
    ]),
    ('2', 0, ['D', 'E'], [
      [0, 60],
    ]),
  ]);
  // Next export: patterns renumbered, line 2 first, and a new line 3.
  final next = syntheticIndex(stops: _stops, patterns: [
    ('3', 3, ['A', 'D'], [
      [0, 60],
    ]),
    ('2', 0, ['D', 'E'], [
      [0, 60],
    ]),
    ('1', 3, ['A', 'B', 'C'], [
      [0, 60, 120],
    ]),
  ]);

  test('geometry follows its line to a new pattern number', () {
    final bytes = encodeLines(_built(old));
    final r = rebaseLines(decodeLines(bytes), next);
    expect(r.matched, 2);
    expect(r.synthetic, 1);
    final line1 = r.net[2]!;
    expect(line1.synthetic, isFalse);
    expect(line1.vertexCount, 5); // the bends came along
    expect(r.net[1]!.synthetic, isFalse);
  });

  test('a new line is drawn through its stops, every hop approximate', () {
    final r = rebaseLines(decodeLines(encodeLines(_built(old))), next);
    final line3 = r.net[0]!;
    expect(line3.synthetic, isTrue);
    expect(line3.vertexCount, 2);
    expect(line3.stopVertex, [0, 1]);
    expect(line3.hopApprox, [1]);
  });

  test('a rerouted line (other stops) is not given the old geometry', () {
    final rerouted = syntheticIndex(stops: _stops, patterns: [
      ('1', 3, ['A', 'E', 'C'], [
        [0, 60, 120],
      ]),
    ]);
    final r = rebaseLines(_built(old), rerouted);
    expect(r.matched, 0);
    expect(r.net[0]!.synthetic, isTrue);
  });

  test('no lines file at all still draws every pattern, dotted', () {
    final r = rebaseLines(null, next);
    expect(r.matched, 0);
    expect(r.synthetic, next.patternCount);
  });

  test('a format 1 file is used by number for its own feed only', () {
    final v1 = LineNetwork(old.feedVersion,
        [for (var p = 0; p < old.patternCount; p++) _geom(old, p)]);
    expect(rebaseLines(v1, old).matched, 2);
    final otherFeed = syntheticIndex(stops: _stops, patterns: [
      ('1', 3, ['A', 'B', 'C'], [
        [0, 60, 120],
      ]),
    ]);
    // Same numbers would hand line 1 the geometry of whatever was pattern 0;
    // without signatures and with another feed nothing is trusted.
    expect(
        rebaseLines(
                LineNetwork('other-feed', [_geom(old, 0)]), otherFeed)
            .matched,
        0);
  });

  test('a focused line without geometry is marked approximate on the map', () {
    final r = rebaseLines(null, next);
    final lines = routeFocusLines(next, r.net, next.patternRoute[0]);
    final props = (lines['features'] as List).single['properties'] as Map;
    expect(props['approx'], 1);
  });
}
