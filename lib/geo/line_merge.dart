/// Merging snapped patterns into the ambient network (§9.4/§9.5).
///
/// Merge by **shared OSM way identity**, same mode only — never by proximity
/// (lesson 4). Both directions of one way collapse into one segment; the
/// direction set is kept so §9.6 can draw an arrow only where a segment is
/// used in exactly one direction.
library;

import 'dart:math' as math;

class MergedSeg {
  MergedSeg(this.aLat, this.aLon, this.bLat, this.bLon, this.mode, this.way);

  /// Mutable only so §9.5 can push a shared bus/tram street apart.
  double aLat, aLon, bLat, bLon;
  final int mode;
  final int way;

  /// Route short names sharing this segment. Its size is the merge count `n`.
  final Set<String> routes = {};

  /// 0 = drawn direction, 1 = against it.
  final Set<int> dirs = {};

  bool get oneDirection => dirs.length == 1;
}

class LineMerger {
  final _merged = <String, MergedSeg>{};

  void add({
    required int mode,
    required String route,
    required int way,
    required double aLat,
    required double aLon,
    required double bLat,
    required double bLon,
  }) {
    if (way < 0) return; // chord: not part of the ambient network
    final forward = (aLat < bLat) || (aLat == bLat && aLon <= bLon);
    final key = '$mode/$way/'
        '${forward ? '$aLat,$aLon,$bLat,$bLon' : '$bLat,$bLon,$aLat,$aLon'}';
    final seg = _merged.putIfAbsent(
      key,
      () => forward
          ? MergedSeg(aLat, aLon, bLat, bLon, mode, way)
          : MergedSeg(bLat, bLon, aLat, aLon, mode, way),
    );
    seg.routes.add(route);
    seg.dirs.add(forward ? 0 : 1);
  }

  /// Tram over bus: a shared street draws both, tram on top.
  List<MergedSeg> get segments =>
      _merged.values.toList()..sort((a, b) => a.mode.compareTo(b.mode));
}

/// Stroke width for `n` merged routes, capped at 3x the single-line width.
double mergedWidth(int n, {double base = 4.0}) =>
    base * math.min(1 + 0.4 * (n - 1), 3.0);

/// A run of merged segments sharing mode, route set and direction set (§9.4).
///
/// `pts` is a flat lat,lon polyline, oriented in the travel direction when the
/// chain is used in exactly one direction, so a chevron layer points right.
class MergedChain {
  MergedChain(this.mode, this.routes, this.oneDirection, this.pts);
  final int mode;
  final List<String> routes;
  final bool oneDirection;
  final List<double> pts;
}

/// Packs a coordinate pair into one int key: lat < 2^26, lon < 2^23 in
/// microdegrees over Turin. Exact coordinates only — no tolerance (lesson 4).
int _key(double lat, double lon) =>
    ((lat * 1e6).round() << 23) | ((lon * 1e6).round() & 0x7FFFFF);

/// Chains consecutive segments of the same `(mode, routes, dirs)` into
/// polylines; breaks where the set changes or the road forks.
List<MergedChain> chainSegments(List<MergedSeg> segs) {
  final groups = <String, List<MergedSeg>>{};
  for (final s in segs) {
    final routes = s.routes.toList()..sort();
    groups
        .putIfAbsent('${s.mode}|${routes.join(",")}|${s.dirs.length}', () => [])
        .add(s);
  }

  final out = <MergedChain>[];
  for (final group in groups.values) {
    final first = group.first;
    final routes = first.routes.toList()..sort();
    final oneWay = first.oneDirection;

    // Oriented endpoints: a one-direction segment drawn against its stored
    // order is flipped, so geometry order equals travel direction (§9.6).
    final aLat = <double>[], aLon = <double>[], bLat = <double>[], bLon = <double>[];
    for (final s in group) {
      final flip = oneWay && s.dirs.contains(1);
      aLat.add(flip ? s.bLat : s.aLat);
      aLon.add(flip ? s.bLon : s.aLon);
      bLat.add(flip ? s.aLat : s.bLat);
      bLon.add(flip ? s.aLon : s.bLon);
    }

    final fromStart = <int, List<int>>{};
    final inDegree = <int, int>{};
    for (var i = 0; i < group.length; i++) {
      fromStart.putIfAbsent(_key(aLat[i], aLon[i]), () => []).add(i);
      inDegree.update(_key(bLat[i], bLon[i]), (v) => v + 1, ifAbsent: () => 1);
    }

    final used = List<bool>.filled(group.length, false);
    void walk(int start) {
      final pts = <double>[aLat[start], aLon[start]];
      var i = start;
      while (true) {
        used[i] = true;
        pts..add(bLat[i])..add(bLon[i]);
        final next = fromStart[_key(bLat[i], bLon[i])];
        // Only continue where the run is unambiguous: one way in, one way out.
        if (next == null || next.length != 1 || used[next.first]) break;
        if ((inDegree[_key(bLat[i], bLon[i])] ?? 0) != 1) break;
        i = next.first;
      }
      out.add(MergedChain(first.mode, routes, oneWay, pts));
    }

    for (var i = 0; i < group.length; i++) {
      if (used[i]) continue;
      if ((inDegree[_key(aLat[i], aLon[i])] ?? 0) == 0) walk(i);
    }
    for (var i = 0; i < group.length; i++) {
      if (!used[i]) walk(i); // rings: no natural start
    }
  }
  return out;
}
