/// Geometry quality report over `build/lines.bin` (bus and tram patterns).
///
///     dart tool/lines_quality.dart [--fail]
///
/// Counts what the eye sees, not only what the build tracks:
///  - approximate (dotted) length, straight chords, and the longest of them
///  - detour ratio: path length / GTFS shape length per pattern
///  - deviation: how far the path strays from the shape and the shape from it
///  - stop offsets that are not monotone along the path
///  - spurs: there-and-back stubs and >150 deg folds between short segments
/// With --fail the exit code is 1 when a hard limit is broken.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:piedemove/data/gtfs_zip.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/distance.dart';
import 'package:piedemove/geo/line_build.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/pattern_snap.dart';
import 'package:piedemove/geo/road_graph.dart' show bearingBetween, bearingDelta;

const detourLimit = 1.3;
const deviationLimitMetres = 60.0;
const spurSegmentMetres = 15.0;

class QualityReport {
  int patterns = 0, hops = 0, approxHops = 0;
  double pathMetres = 0, approxMetres = 0, maxApproxRun = 0;
  int approxRuns = 0, longApproxRuns = 0;
  int detourOver = 0, deviationOver = 0, nonMonotone = 0, spurs = 0, folds = 0;
  int noShape = 0;
  final ratios = <double>[];
  final worstDeviation = <double>[];
  final spurAt = <String>[];
  final devAt = <(double, String)>[];
}

double _segMetres(SnappedPattern p, int i) => haversineMetres(
    p.vertexLat[i] / 1e6, p.vertexLon[i] / 1e6,
    p.vertexLat[i + 1] / 1e6, p.vertexLon[i + 1] / 1e6);

/// Scores one pattern into [r]. [shape] may be null.
void scorePattern(QualityReport r, SnappedPattern p, ShapePolyline? shape) {
  r.patterns++;
  r.hops += p.hopApprox.length;
  r.approxHops += p.approxHops;
  var path = 0.0, run = 0.0;
  for (var i = 0; i + 1 < p.vertexCount; i++) {
    final d = _segMetres(p, i);
    path += d;
    if (p.vertexWay[i + 1] < 0) {
      r.approxMetres += d;
      run += d;
    } else if (run > 0) {
      _endRun(r, run);
      run = 0;
    }
  }
  if (run > 0) _endRun(r, run);
  r.pathMetres += path;

  for (var i = 0; i + 1 < p.stopVertex.length; i++) {
    if (p.stopVertex[i + 1] < p.stopVertex[i]) r.nonMonotone++;
  }
  // Spur: a fold of more than 150 degrees between two short matched segments,
  // not at a stop (a bus reversing at a dead-end stop is real).
  final stopAt = {for (final v in p.stopVertex) v};
  for (var i = 1; i + 1 < p.vertexCount; i++) {
    if (p.vertexWay[i] < 0 || p.vertexWay[i + 1] < 0 || stopAt.contains(i)) continue;
    final a = _segMetres(p, i - 1), b = _segMetres(p, i);
    if (a > spurSegmentMetres || b > spurSegmentMetres || a < 0.5 || b < 0.5) {
      continue;
    }
    final b1 = bearingBetween(p.vertexLat[i - 1] / 1e6, p.vertexLon[i - 1] / 1e6,
        p.vertexLat[i] / 1e6, p.vertexLon[i] / 1e6);
    final b2 = bearingBetween(p.vertexLat[i] / 1e6, p.vertexLon[i] / 1e6,
        p.vertexLat[i + 1] / 1e6, p.vertexLon[i + 1] / 1e6);
    if (bearingDelta(b1, b2) > 150) {
      r.folds++;
      // A fold the shape itself makes (a turnaround) is real; one the matcher
      // made up, away from the shape, is a spur.
      if (shape != null && shape.distanceTo(p.vertexLat[i] / 1e6, p.vertexLon[i] / 1e6) <= 20) {
        continue;
      }
      r.spurs++;
      r.spurAt.add('pattern ${p.pattern} ${p.vertexLat[i] / 1e6},${p.vertexLon[i] / 1e6} '
          'legs ${a.round()}/${b.round()} m');
    }
  }

  if (shape == null) {
    r.noShape++;
    return;
  }
  var shapeLen = 0.0;
  for (var i = 0; i + 1 < shape.lat.length; i++) {
    shapeLen += haversineMetres(
        shape.lat[i], shape.lon[i], shape.lat[i + 1], shape.lon[i + 1]);
  }
  final ratio = shapeLen == 0 ? 1.0 : path / shapeLen;
  r.ratios.add(ratio);
  if (ratio > detourLimit) r.detourOver++;

  // Path -> shape (matched vertices only), and shape -> path at ~30 m steps.
  var worst = 0.0, worstAt = '';
  void see(double d, double la, double lo, String kind) {
    if (d > worst) {
      worst = d;
      worstAt = 'pattern ${p.pattern} $kind $la,$lo';
    }
  }

  for (var i = 0; i < p.vertexCount; i++) {
    if (p.vertexWay[i] < 0) continue;
    see(shape.distanceTo(p.vertexLat[i] / 1e6, p.vertexLon[i] / 1e6),
        p.vertexLat[i] / 1e6, p.vertexLon[i] / 1e6, 'path-off-shape');
  }
  final pathLine = ShapePolyline(
    Float64List.fromList([for (var i = 0; i < p.vertexCount; i++) p.vertexLat[i] / 1e6]),
    Float64List.fromList([for (var i = 0; i < p.vertexCount; i++) p.vertexLon[i] / 1e6]),
  );
  var carry = 0.0;
  for (var i = 0; i + 1 < shape.lat.length; i++) {
    final d = haversineMetres(
        shape.lat[i], shape.lon[i], shape.lat[i + 1], shape.lon[i + 1]);
    var t = carry;
    for (; t < d; t += 30) {
      final f = d == 0 ? 0.0 : t / d;
      final la = shape.lat[i] + (shape.lat[i + 1] - shape.lat[i]) * f;
      final lo = shape.lon[i] + (shape.lon[i + 1] - shape.lon[i]) * f;
      see(pathLine.distanceTo(la, lo), la, lo, 'shape-off-path');
    }
    carry = t - d;
  }
  r.worstDeviation.add(worst);
  r.devAt.add((worst, worstAt));
  if (worst > deviationLimitMetres) r.deviationOver++;
}

void _endRun(QualityReport r, double run) {
  r.approxRuns++;
  r.maxApproxRun = math.max(r.maxApproxRun, run);
  if (run > 200) r.longApproxRuns++;
}

double _pct(List<double> xs, double q) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  return s[math.min(s.length - 1, (q * s.length).floor())];
}

Future<void> main(List<String> args) async {
  final ix = await readIndexFile('build/index.bin');
  final net = await readLinesFile('build/lines.bin');
  if (ix == null || net == null) {
    stderr.writeln('need build/index.bin and build/lines.bin');
    exit(1);
  }
  final zip = GtfsZip('build/gtt_gtfs.zip', Directory('build'));
  final shapeIds = await patternShapeIds(zip, ix);
  final shapes = await readShapes(zip, shapeIds.whereType<String>().toSet());
  zip.close();

  final r = QualityReport();
  for (final p in net.patterns) {
    final type = ix.routeTypeOfPattern(p.pattern);
    if (type != RouteType.bus && type != RouteType.tram) continue;
    scorePattern(r, p, shapes[shapeIds[p.pattern]]);
  }
  String f(double v, [int d = 1]) => v.toStringAsFixed(d);
  stdout.writeln('''
patterns        ${r.patterns} (no shape ${r.noShape})
hops            ${r.hops}, approximate ${r.approxHops} (${f(100 * r.approxHops / math.max(1, r.hops), 2)}%)
path length     ${f(r.pathMetres / 1000, 0)} km, dotted ${f(r.approxMetres / 1000)} km (${f(100 * r.approxMetres / math.max(1, r.pathMetres), 2)}%)
dotted runs     ${r.approxRuns}, longest ${f(r.maxApproxRun, 0)} m, over 200 m: ${r.longApproxRuns}
detour ratio    p50 ${f(_pct(r.ratios, .5), 3)} p95 ${f(_pct(r.ratios, .95), 3)} max ${f(_pct(r.ratios, 1), 2)}; over $detourLimit: ${r.detourOver}
deviation       p50 ${f(_pct(r.worstDeviation, .5))} p95 ${f(_pct(r.worstDeviation, .95))} m; patterns over ${deviationLimitMetres.toInt()} m: ${r.deviationOver}
non-monotone    ${r.nonMonotone} stop offsets
spurs           ${r.spurs} invented (${r.folds} short folds in all, the rest are shape turnarounds)''');
  if (args.contains('--dev')) {
    r.devAt.sort((a, b) => b.$1.compareTo(a.$1));
    for (final d in r.devAt.take(30)) {
      stdout.writeln('${d.$1.round()} m ${d.$2}');
    }
  }
  if (args.contains('--spurs')) r.spurAt.take(40).forEach(stdout.writeln);
  if (args.contains('--fail') &&
      (r.nonMonotone > 0 || r.spurs > 0 || r.approxHops > 0.01 * r.hops)) {
    exit(1);
  }
}
