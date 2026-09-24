/// Gap detector for the line network (FIX_MASTER phase 1).
///
///     dart tool/gap_detector.dart [-v]
///
/// Walks every snapped pattern in `assets/lines.bin.gz` (after the same spur
/// clean-up the ambient build applies) and checks that the geometry the map
/// really draws (`assets/ambient.json.gz`, the exact string handed to MapLibre)
/// contains each hop, end to end:
///   * missing   - no single drawn feature passes within [matchMetres] of both
///                 ends of a hop (chords must ship as `approx = 1` features)
///   * joint     - two consecutive hops whose drawn features are different and
///                 whose end points do not meet within [joinMetres]
///
/// Smoothing moves interior vertices by at most [smoothTotalDeviationMetres]
/// and the bus/tram shift by 3 m, so vertices are matched to the drawn
/// polyline, not to drawn vertices; chain ends are exact, so joints are not.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:piedemove/geo/line_smooth.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/pattern_snap.dart';

/// Two drawn features meeting closer than this are joined (sub-2 m connector
/// features bridge the rest).
const joinMetres = 2.0;
const matchMetres = smoothTotalDeviationMetres + 3.0;

class Gap {
  Gap(this.pattern, this.hop, this.cause, this.detail);
  final int pattern, hop;
  final String cause, detail;
  @override
  String toString() => 'pattern $pattern vertex $hop: $cause $detail';
}

const _mLat = 111320.0, _mLon = 111320.0 * 0.707;

/// Drawn features indexed by ~25 m cell for point-to-polyline queries.
class EmittedGeometry {
  EmittedGeometry(Map<String, dynamic> collection) {
    for (final f in collection['features'] as List) {
      final coords = (f['geometry']['coordinates'] as List);
      final id = _lines.length;
      final xs = Float64List(coords.length), ys = Float64List(coords.length);
      for (var i = 0; i < coords.length; i++) {
        xs[i] = (coords[i][0] as num) * _mLon;
        ys[i] = (coords[i][1] as num) * _mLat;
      }
      _lines.add((xs, ys));
      for (var i = 1; i < coords.length; i++) {
        final n = math.max(1,
            (math.sqrt(math.pow(xs[i] - xs[i - 1], 2) + math.pow(ys[i] - ys[i - 1], 2)) / (_cell / 4)).ceil());
        int? last;
        for (var k = 0; k <= n; k++) {
          final t = k / n;
          final c = _cellOf(ys[i - 1] + (ys[i] - ys[i - 1]) * t,
              xs[i - 1] + (xs[i] - xs[i - 1]) * t);
          if (c == last) continue;
          last = c;
          (_cells[c] ??= <int, List<int>>{}).putIfAbsent(id, () => []).add(i);
        }
      }
    }
  }

  static const _cell = 25.0;
  final _lines = <(Float64List, Float64List)>[];
  final _cells = <int, Map<int, List<int>>>{};

  static int _cellOf(double y, double x) =>
      ((y / _cell).floor() << 24) ^ ((x / _cell).floor() & 0xFFFFFF);

  /// Ids of drawn features within [tol] metres of the point.
  Set<int> near(double lat, double lon, {double tol = matchMetres}) {
    final y = lat * _mLat, x = lon * _mLon;
    final out = <int>{};
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final m = _cells[_cellOf(y + dy * _cell, x + dx * _cell)];
        if (m == null) continue;
        m.forEach((id, segs) {
          if (out.contains(id)) return;
          final (xs, ys) = _lines[id];
          for (final i in segs) {
            if (_distToSeg(x, y, xs[i - 1], ys[i - 1], xs[i], ys[i]) <= tol) {
              out.add(id);
              return;
            }
          }
        });
      }
    }
    return out;
  }

  /// Whether two features touch within [joinMetres]: an end of one on the
  /// other, or the two crossing (a route may change chain at a node both pass
  /// through).
  bool joined(int a, int b) {
    final (ax, ay) = _lines[a];
    final (bx, by) = _lines[b];
    for (var i = 1; i < ax.length; i++) {
      for (var j = 1; j < bx.length; j++) {
        if (_segSeg(ax[i - 1], ay[i - 1], ax[i], ay[i], bx[j - 1], by[j - 1],
                bx[j], by[j]) <=
            joinMetres) {
          return true;
        }
      }
    }
    return false;
  }
}

double _cross(double ax, double ay, double bx, double by, double cx, double cy) =>
    (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);

/// Distance between two segments: 0 when they cross.
double _segSeg(double ax, double ay, double bx, double by, double cx, double cy,
    double dx, double dy) {
  final d1 = _cross(ax, ay, bx, by, cx, cy), d2 = _cross(ax, ay, bx, by, dx, dy);
  final d3 = _cross(cx, cy, dx, dy, ax, ay), d4 = _cross(cx, cy, dx, dy, bx, by);
  if (d1 * d2 < 0 && d3 * d4 < 0) return 0;
  return [
    _distToSeg(ax, ay, cx, cy, dx, dy),
    _distToSeg(bx, by, cx, cy, dx, dy),
    _distToSeg(cx, cy, ax, ay, bx, by),
    _distToSeg(dx, dy, ax, ay, bx, by),
  ].reduce(math.min);
}

double _distToSeg(double px, double py, double ax, double ay, double bx, double by) {
  final dx = bx - ax, dy = by - ay;
  final l2 = dx * dx + dy * dy;
  final t = l2 == 0 ? 0.0 : (((px - ax) * dx + (py - ay) * dy) / l2).clamp(0.0, 1.0);
  return math.sqrt(math.pow(px - ax - t * dx, 2) + math.pow(py - ay - t * dy, 2));
}

double _hopMetres(SnappedPattern p, int a, int b) => math.sqrt(
    math.pow((p.vertexLat[a] - p.vertexLat[b]) / 1e6 * _mLat, 2) +
        math.pow((p.vertexLon[a] - p.vertexLon[b]) / 1e6 * _mLon, 2));

List<Gap> findGaps(LineNetwork net, EmittedGeometry emitted) {
  final gaps = <Gap>[];
  for (final p in net.patterns) {
    final kept = spurFreeIndices(p.vertexLat, p.vertexLon);
    final near = <int, Set<int>>{};
    Set<int> at(int i) => near.putIfAbsent(
        i, () => emitted.near(p.vertexLat[i] / 1e6, p.vertexLon[i] / 1e6));
    Set<int>? prev;
    for (var k = 1; k < kept.length; k++) {
      final i = kept[k], a = kept[k - 1];
      var cur = at(a).intersection(at(i));
      if (cur.isEmpty) {
        // A stub tip is dropped from drawn chains (spike removal), so a hop to
        // or from one ends up to [spurMaxLegMetres] short of the drawn line.
        final wideA = emitted.near(p.vertexLat[a] / 1e6, p.vertexLon[a] / 1e6,
            tol: matchMetres + spurMaxLegMetres);
        final wideI = emitted.near(p.vertexLat[i] / 1e6, p.vertexLon[i] / 1e6,
            tol: matchMetres + spurMaxLegMetres);
        final wide = wideA.isNotEmpty && wideI.isNotEmpty ? wideA : <int>{};
        if (wide.isNotEmpty && _hopMetres(p, a, i) <= 2 * spurMaxLegMetres) {
          prev = null;
          continue;
        }
      }
      if (cur.isEmpty) {
        gaps.add(Gap(p.pattern, i, p.vertexWay[i] < 0 ? 'missing-chord' : 'missing-hop',
            'at ${p.vertexLat[a] / 1e6},${p.vertexLon[a] / 1e6}'));
        prev = null;
        continue;
      }
      if (prev != null &&
          prev.intersection(cur).isEmpty &&
          !prev.any((f1) => cur.any((f2) => emitted.joined(f1, f2)))) {
        gaps.add(Gap(p.pattern, a, 'joint',
            'ends differ at ${p.vertexLat[a] / 1e6},${p.vertexLon[a] / 1e6}'));
      }
      prev = cur;
    }
  }
  return gaps;
}

Map<String, dynamic> readGz(String path) =>
    jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync())))
        as Map<String, dynamic>;

LineNetwork readNet(String path) => decodeLines(
    Uint8List.fromList(gzip.decode(File(path).readAsBytesSync())))!;

void main(List<String> args) {
  final net = readNet('assets/lines.bin.gz');
  final gaps = findGaps(net, EmittedGeometry(readGz('assets/ambient.json.gz')));
  final byCause = <String, int>{};
  for (final g in gaps) {
    byCause.update(g.cause, (v) => v + 1, ifAbsent: () => 1);
  }
  stdout.writeln('patterns ${net.patterns.length}, gaps ${gaps.length} $byCause');
  for (final g in gaps.take(args.contains('-v') ? 200 : 15)) {
    stdout.writeln('  $g');
  }
  exit(gaps.isEmpty ? 0 : 1);
}
