/// Knot detector for the emitted ambient geometry.
///
///     dart tool/knot_detector.dart
///
/// A knot is a place where one drawn line folds back on itself or crosses
/// itself: a spike (a vertex turning more than [knotDegrees] with both legs at
/// least [knotMinLegMetres] and at most [chainSpikeMaxLegMetres]), or a kink loop
/// (two non-adjacent segments of one feature crossing within
/// [knotLoopMetres] of line length). Long hairpins and big loops are real road
/// geometry, not knots, and a fold or loop holding a junction (another feature ends there)
/// is a real branch, not a spike. Approximate chords are two-point lines.
library;

import 'dart:io';
import 'dart:math' as math;

import 'gap_detector.dart';

/// Two degrees above the cleaner's cut-off: coordinates are rounded to 6
/// decimals after cleaning.
const knotDegrees = 150.0;
const knotMinLegMetres = 2.0;
const knotLoopMetres = 80.0;
const chainSpikeMaxLegMetres = 15.0;

/// Exact-coordinate key of a drawn vertex (6 decimals).
int jointKey(double lat, double lon) =>
    ((lat * 1e6).round() << 23) | ((lon * 1e6).round() & 0x7FFFFF);

const _mLat = 111320.0, _mLon = 111320.0 * 0.707;

class Knot {
  Knot(this.feature, this.kind, this.where);
  final int feature;
  final String kind, where;
  @override
  String toString() => 'feature $feature: $kind at $where';
}

List<Knot> findKnots(Map<String, dynamic> collection) {
  final out = <Knot>[];
  final features = collection['features'] as List;
  final junctions = <int>{
    for (final f in features)
      for (final c in [
        (f['geometry']['coordinates'] as List).first,
        (f['geometry']['coordinates'] as List).last,
      ])
        jointKey((c[1] as num).toDouble(), (c[0] as num).toDouble()),
  };
  for (var f = 0; f < features.length; f++) {
    final props = features[f]['properties'] as Map;
    if (props['approx'] == 1) continue;
    final cs = features[f]['geometry']['coordinates'] as List;
    final x = [for (final c in cs) (c[0] as num) * _mLon];
    final y = [for (final c in cs) (c[1] as num) * _mLat];
    for (var i = 1; i < cs.length - 1; i++) {
      final ax = x[i] - x[i - 1], ay = y[i] - y[i - 1];
      final bx = x[i + 1] - x[i], by = y[i + 1] - y[i];
      final la = math.sqrt(ax * ax + ay * ay), lb = math.sqrt(bx * bx + by * by);
      if (la < knotMinLegMetres || lb < knotMinLegMetres) continue;
      final turn = math.acos(((ax * bx + ay * by) / (la * lb)).clamp(-1.0, 1.0)) *
          180 / math.pi;
      if (turn > knotDegrees &&
          math.max(la, lb) <= chainSpikeMaxLegMetres &&
          !junctions.contains(
              jointKey((cs[i][1] as num).toDouble(), (cs[i][0] as num).toDouble()))) {
        out.add(Knot(f, 'fold ${turn.round()} deg', '${cs[i][1]},${cs[i][0]}'));
      }
    }
    for (var i = 1; i < cs.length; i++) {
      var along = 0.0;
      for (var j = i + 2; j < cs.length; j++) {
        along += math.sqrt(math.pow(x[j - 1] - x[j - 2], 2) + math.pow(y[j - 1] - y[j - 2], 2));
        if (along > knotLoopMetres) break;
        if ([for (var k = i; k < j; k++) k].any((k) => junctions.contains(jointKey(
            (cs[k][1] as num).toDouble(), (cs[k][0] as num).toDouble())))) {
          continue; // a chain attaches inside the loop: a real junction
        }
        if (_cross(x[i - 1], y[i - 1], x[i], y[i], x[j - 1], y[j - 1], x[j], y[j])) {
          out.add(Knot(f, 'self-cross', '${cs[i][1]},${cs[i][0]}'));
        }
      }
    }
  }
  return out;
}

bool _cross(double ax, double ay, double bx, double by, double cx, double cy,
    double dx, double dy) {
  double o(double px, double py, double qx, double qy, double rx, double ry) =>
      (qx - px) * (ry - py) - (qy - py) * (rx - px);
  final d1 = o(ax, ay, bx, by, cx, cy), d2 = o(ax, ay, bx, by, dx, dy);
  final d3 = o(cx, cy, dx, dy, ax, ay), d4 = o(cx, cy, dx, dy, bx, by);
  return d1 * d2 < 0 && d3 * d4 < 0;
}

void main() {
  final knots = findKnots(readGz('assets/ambient.json.gz'));
  stdout.writeln('knots ${knots.length}');
  for (final k in knots.take(15)) {
    stdout.writeln('  $k');
  }
  exit(knots.isEmpty ? 0 : 1);
}
