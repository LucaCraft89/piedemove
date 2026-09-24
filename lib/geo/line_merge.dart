/// Merging matched patterns into the ambient network (§9.4).
///
/// Merge by **graph segment identity**: the physical segment between two OSM
/// nodes of one mode is one [MergedSeg], whatever pattern, direction or stop
/// positions produced it. Never by proximity (lesson 4), never by coordinate
/// distance. Two directions on one two-way segment collapse into one; divided
/// roads have one way per carriageway, so each lands on its own lane.
///
/// Patterns are matched onto **whole** segments (stops do not split them), so
/// two routes over the same street produce identical segments and the chains
/// below join and break in exactly the same places for every route.
library;

import 'dart:math' as math;

class MergedSeg {
  MergedSeg(this.mode, this.a, this.b, this.aLat, this.aLon, this.bLat, this.bLon);

  final int mode;

  /// Graph node ids, `a < b` (canonical orientation).
  final int a, b;
  final double aLat, aLon, bLat, bLon;

  /// Route short names sharing this segment. Its size is the merge count `n`.
  final Set<String> routes = {};

  /// 0 = travelled a -> b, 1 = travelled b -> a.
  final Set<int> dirs = {};

  bool get oneDirection => dirs.length == 1;
}

class LineMerger {
  final _merged = <String, MergedSeg>{};

  /// Records that [route] travels the segment [from] -> [to] of [mode].
  void add({
    required int mode,
    required String route,
    required int from,
    required int to,
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
  }) {
    if (from == to) return;
    final forward = from < to;
    final seg = _merged.putIfAbsent(
      '$mode/${forward ? from : to}/${forward ? to : from}',
      () => forward
          ? MergedSeg(mode, from, to, fromLat, fromLon, toLat, toLon)
          : MergedSeg(mode, to, from, toLat, toLon, fromLat, fromLon),
    );
    seg.routes.add(route);
    seg.dirs.add(forward ? 0 : 1);
  }

  List<MergedSeg> get segments => _merged.values.toList();
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

/// Chains segments of the same `(mode, routes, dirs)` into polylines. A chain
/// breaks exactly where the group's own network forks, ends, or changes set.
List<MergedChain> chainSegments(List<MergedSeg> segs) {
  final groups = <String, List<MergedSeg>>{};
  for (final s in segs) {
    final routes = s.routes.toList()..sort();
    groups
        .putIfAbsent('${s.mode}|${routes.join(",")}|${s.dirs.length}', () => [])
        .add(s);
  }
  final out = <MergedChain>[];
  for (final g in groups.values) {
    final routes = g.first.routes.toList()..sort();
    final oneWay = g.first.oneDirection;
    out.addAll(oneWay
        ? _directed(g, routes)
        : _undirected(g, routes));
  }
  return out;
}

// One-direction group: every segment oriented along its travel direction.
List<MergedChain> _directed(List<MergedSeg> g, List<String> routes) {
  final from = <int>[], to = <int>[];
  final pts = <List<double>>[]; // fromLat, fromLon, toLat, toLon
  for (final s in g) {
    final flip = s.dirs.contains(1);
    from.add(flip ? s.b : s.a);
    to.add(flip ? s.a : s.b);
    pts.add(flip
        ? [s.bLat, s.bLon, s.aLat, s.aLon]
        : [s.aLat, s.aLon, s.bLat, s.bLon]);
  }
  final outOf = <int, List<int>>{};
  final inDeg = <int, int>{};
  for (var i = 0; i < g.length; i++) {
    (outOf[from[i]] ??= []).add(i);
    inDeg.update(to[i], (v) => v + 1, ifAbsent: () => 1);
  }
  bool through(int node) => (inDeg[node] ?? 0) == 1 && (outOf[node]?.length ?? 0) == 1;

  final used = List<bool>.filled(g.length, false);
  final out = <MergedChain>[];
  void walk(int start) {
    final line = <double>[pts[start][0], pts[start][1]];
    var i = start;
    while (true) {
      used[i] = true;
      line..add(pts[i][2])..add(pts[i][3]);
      if (!through(to[i])) break;
      final next = outOf[to[i]]!.first;
      if (used[next]) break;
      i = next;
    }
    out.add(MergedChain(g.first.mode, routes, true, line));
  }

  for (var i = 0; i < g.length; i++) {
    if (!used[i] && !through(from[i])) walk(i);
  }
  for (var i = 0; i < g.length; i++) {
    if (!used[i]) walk(i); // rings: no natural start
  }
  return out;
}

// Two-direction group: undirected walk, arbitrary orientation.
List<MergedChain> _undirected(List<MergedSeg> g, List<String> routes) {
  final at = <int, List<int>>{};
  for (var i = 0; i < g.length; i++) {
    (at[g[i].a] ??= []).add(i);
    (at[g[i].b] ??= []).add(i);
  }
  bool through(int node) => (at[node]?.length ?? 0) == 2;

  final used = List<bool>.filled(g.length, false);
  final out = <MergedChain>[];
  void walk(int start, bool fromA) {
    var i = start;
    var head = fromA ? g[i].a : g[i].b; // node we leave
    final line = fromA
        ? <double>[g[i].aLat, g[i].aLon]
        : <double>[g[i].bLat, g[i].bLon];
    while (true) {
      used[i] = true;
      final s = g[i];
      final leavesToB = head == s.a;
      final tail = leavesToB ? s.b : s.a;
      line
        ..add(leavesToB ? s.bLat : s.aLat)
        ..add(leavesToB ? s.bLon : s.aLon);
      if (!through(tail)) break;
      final next = at[tail]!.firstWhere((k) => k != i, orElse: () => i);
      if (next == i || used[next]) break;
      head = tail;
      i = next;
    }
    out.add(MergedChain(g.first.mode, routes, false, line));
  }

  for (var i = 0; i < g.length; i++) {
    if (used[i]) continue;
    if (!through(g[i].a)) {
      walk(i, true);
    } else if (!through(g[i].b)) {
      walk(i, false);
    }
  }
  for (var i = 0; i < g.length; i++) {
    if (!used[i]) walk(i, true); // rings
  }
  return out;
}
