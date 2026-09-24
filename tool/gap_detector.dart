/// Gap detector for the line network (FIX_MASTER phase 1).
///
///     dart tool/gap_detector.dart [-v]
///
/// Walks every snapped pattern in `assets/lines.bin.gz` and checks that the
/// geometry the map really draws (`assets/ambient.json.gz`, the exact string
/// handed to MapLibre) contains each pattern segment, end to end:
///   * missing   - no emitted edge within [joinMetres] of both ends of a hop
///                 segment (this also catches features that fail to share an
///                 endpoint, since both ends must land on emitted vertices)
///   * joint     - two consecutive hop segments whose drawn ends do not meet
/// Chords are flagged approximate in the data and must be emitted as
/// `approx = 1` features; a missing chord is a `missing` gap like any other.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:piedemove/geo/lines_io.dart';

/// [joinMetres]: two drawn edges meeting at a vertex must share it this
/// closely. [matchMetres]: how far a drawn edge may sit from the stored
/// vertex (the shared bus/tram street is pushed 3 m aside at build time).
const joinMetres = 1.0, matchMetres = 4.0;

class Gap {
  Gap(this.pattern, this.hop, this.cause, this.detail);
  final int pattern, hop;
  final String cause, detail;
  @override
  String toString() => 'pattern $pattern vertex $hop: $cause $detail';
}

double _m(double aLat, double aLon, double bLat, double bLon) {
  final dy = (aLat - bLat) * 111320;
  final dx = (aLon - bLon) * 111320 * 0.707;
  return math.sqrt(dy * dy + dx * dx);
}

/// Emitted edges of a FeatureCollection, indexed by endpoint cell.
class EmittedGeometry {
  EmittedGeometry(Map<String, dynamic> collection) {
    for (final f in collection['features'] as List) {
      final coords = (f['geometry']['coordinates'] as List);
      for (var i = 1; i < coords.length; i++) {
        final a = coords[i - 1] as List, b = coords[i] as List;
        final e = [
          (a[1] as num).toDouble(), (a[0] as num).toDouble(),
          (b[1] as num).toDouble(), (b[0] as num).toDouble(),
        ];
        _cells.putIfAbsent(_cell(e[0], e[1]), () => []).add(e);
        _cells.putIfAbsent(_cell(e[2], e[3]), () => []).add(e);
      }
    }
  }

  static const _size = 3e-5; // ~3 m, so a 1 m match is in the 3x3 block
  final _cells = <int, List<List<double>>>{};

  static int _cellOf(int y, int x) => (y << 24) ^ (x & 0xFFFFFF);
  int _cell(double lat, double lon) =>
      _cellOf((lat / _size).floor(), (lon / _size).floor());

  /// Emitted edges running from within [tol] m of a to within [tol] m of b,
  /// each oriented a -> b as `[aLat, aLon, bLat, bLon]`.
  List<List<double>> match(double aLat, double aLon, double bLat, double bLon,
      {double tol = matchMetres}) {
    final out = <List<double>>[];
    final y = (aLat / _size).floor(), x = (aLon / _size).floor();
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        for (final e in _cells[_cellOf(y + dy, x + dx)] ?? const <List<double>>[]) {
          // Short hops fit both ways round inside the tolerance: keep the
          // orientation with the smaller total distance.
          final fa = _m(e[0], e[1], aLat, aLon), fb = _m(e[2], e[3], bLat, bLon);
          final ra = _m(e[2], e[3], aLat, aLon), rb = _m(e[0], e[1], bLat, bLon);
          final fwdOk = fa <= tol && fb <= tol, revOk = ra <= tol && rb <= tol;
          if (fwdOk && (!revOk || fa + fb <= ra + rb)) {
            out.add(e);
          } else if (revOk) {
            out.add([e[2], e[3], e[0], e[1]]);
          }
        }
      }
    }
    return out;
  }
}

List<Gap> findGaps(LineNetwork net, EmittedGeometry emitted) {
  final gaps = <Gap>[];
  final cache = <String, List<List<double>>>{};
  for (final p in net.patterns) {
    List<List<double>>? prev;
    for (var i = 1; i < p.vertexCount; i++) {
      final aLat = p.vertexLat[i - 1] / 1e6, aLon = p.vertexLon[i - 1] / 1e6;
      final bLat = p.vertexLat[i] / 1e6, bLon = p.vertexLon[i] / 1e6;
      final len = _m(aLat, aLon, bLat, bLon);
      final cur = cache.putIfAbsent(
          '${p.vertexLat[i - 1]},${p.vertexLon[i - 1]},${p.vertexLat[i]},${p.vertexLon[i]}',
          () => emitted.match(aLat, aLon, bLat, bLon));
      if (cur.isEmpty) {
        gaps.add(Gap(p.pattern, i, p.vertexWay[i] < 0 ? 'missing-chord' : 'missing-hop',
            '${len.round()} m at $aLat,$aLon'));
      } else if (prev != null &&
          !prev.any((e1) => cur.any((e2) =>
              _m(e1[2], e1[3], e2[0], e2[1]) <= joinMetres))) {
        gaps.add(Gap(p.pattern, i - 1, 'joint', 'ends differ at $aLat,$aLon'));
      }
      prev = cur.isEmpty ? null : cur;
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
