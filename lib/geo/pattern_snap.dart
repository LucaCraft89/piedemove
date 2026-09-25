/// Pattern geometry model (§9.3): what one pattern looks like once matched.
///
/// A pattern is **one continuous polyline** ([SnappedPattern.vertexLat]/Lon)
/// plus the vertex index at which each stop sits. Stops are placed by a
/// monotone dynamic programme over the finished path (never by nearest-vertex
/// search), so a stop visited twice on a loop lands on the right pass and the
/// offsets can never run backwards.
///
/// Where a piece of the path is on the road graph, its vertices carry the OSM
/// way and the directed graph edge; where it is the GTFS shape itself the edge
/// is [edgeShape]; where the matcher gave up it is [edgeApprox] and is drawn
/// dotted.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'distance.dart';

/// `vertexEdge` marker: the segment is an unsnapped stretch, drawn dotted.
const edgeApprox = -1;

/// `vertexEdge` marker: the segment is the GTFS shape as published (metro,
/// funicular), exact, not on the road graph.
const edgeShape = -2;

int microdeg(double v) => (v * 1e6).round();

/// A GTFS shape as a polyline with a coarse grid index over its segments.
class ShapePolyline {
  ShapePolyline(this.lat, this.lon) {
    for (var i = 0; i + 1 < lat.length; i++) {
      final loLat = math.min(lat[i], lat[i + 1]);
      final hiLat = math.max(lat[i], lat[i + 1]);
      final loLon = math.min(lon[i], lon[i + 1]);
      final hiLon = math.max(lon[i], lon[i + 1]);
      for (var y = (loLat / _cell).floor(); y <= (hiLat / _cell).floor(); y++) {
        for (var x = (loLon / _cell).floor(); x <= (hiLon / _cell).floor(); x++) {
          (_index[y * 1000000 + x] ??= <int>[]).add(i);
        }
      }
    }
  }

  static const _cell = 0.004; // ~440 m

  final Float64List lat, lon;
  final _index = <int, List<int>>{};

  /// Metres from the point to the nearest shape segment. Falls back to a scan
  /// of every segment when the point is far from any indexed cell.
  double distanceTo(double pLat, double pLon) {
    var best = double.infinity;
    final y0 = (pLat / _cell).floor(), x0 = (pLon / _cell).floor();
    var found = false;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final seg = _index[(y0 + dy) * 1000000 + (x0 + dx)];
        if (seg == null) continue;
        found = true;
        for (final i in seg) {
          final d = _segDistance(i, pLat, pLon);
          if (d < best) best = d;
        }
      }
    }
    if (found) return best;
    for (var i = 0; i + 1 < lat.length; i++) {
      final d = _segDistance(i, pLat, pLon);
      if (d < best) best = d;
    }
    return best;
  }

  double _segDistance(int i, double pLat, double pLon) {
    final scale = math.cos(pLat * math.pi / 180);
    final ax = lon[i] * scale, ay = lat[i];
    final bx = lon[i + 1] * scale, by = lat[i + 1];
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0
        ? 0.0
        : (((pLon * scale - ax) * dx + (pLat - ay) * dy) / len2).clamp(0.0, 1.0);
    return haversineMetres(pLat, pLon, ay + dy * t, (ax + dx * t) / scale);
  }
}


/// One pattern's geometry.
class SnappedPattern {
  SnappedPattern({
    required this.pattern,
    required this.vertexLat,
    required this.vertexLon,
    required this.vertexWay,
    required this.vertexDir,
    required this.stopVertex,
    required this.stopLat,
    required this.stopLon,
    required this.hopApprox,
    this.vertexEdge,
    this.synthetic = false,
  });

  /// The same geometry filed under another pattern number (a newer index).
  SnappedPattern withPattern(int id) => SnappedPattern(
        pattern: id,
        vertexLat: vertexLat,
        vertexLon: vertexLon,
        vertexWay: vertexWay,
        vertexDir: vertexDir,
        stopVertex: stopVertex,
        stopLat: stopLat,
        stopLon: stopLon,
        hopApprox: hopApprox,
        vertexEdge: vertexEdge,
        synthetic: synthetic,
      );

  final int pattern;

  /// Microdegrees.
  final Int32List vertexLat, vertexLon;

  /// OSM way of the segment **leading into** each vertex; -1 for vertex 0 and
  /// for approximate or shape segments. `vertexDir[i] != 0` means that segment
  /// runs against the way's own point order.
  final Int64List vertexWay;
  final Uint8List vertexDir;

  /// Vertex index at which each stop sits: slice by index, never by search.
  final Int32List stopVertex;

  /// Coordinates of the stop's place on the path, microdegrees.
  final Int32List stopLat, stopLon;

  /// One flag per hop (stop i -> i+1); 1 = the hop touches an approximate
  /// (dotted) stretch.
  final Uint8List hopApprox;

  /// Directed graph edge of the segment leading into each vertex, or
  /// [edgeApprox] / [edgeShape]. Only the desktop build has it (edge ids are
  /// not stable across graph builds), so it is not in `lines.bin`.
  final Int32List? vertexEdge;

  /// True when no matched geometry exists for the pattern and this is only
  /// its stops joined by straight lines: drawn dotted, marked approximate.
  final bool synthetic;

  int get vertexCount => vertexLat.length;
  int get approxHops => hopApprox.where((f) => f != 0).length;
}

/// A path under construction: vertices with the attributes of the segment
/// that leads into each of them.
class PathBuilder {
  final lat = <double>[], lon = <double>[];
  final way = <int>[], dir = <int>[], edge = <int>[];

  bool get isEmpty => lat.isEmpty;

  void start(double la, double lo) {
    lat.add(la);
    lon.add(lo);
    way.add(-1);
    dir.add(0);
    edge.add(edgeApprox);
  }

  /// Appends a vertex reached by a segment of the given kind. Repeats of the
  /// last vertex are dropped, so pieces join without zero-length segments.
  void add(double la, double lo, int w, int d, int e) {
    if (lat.isEmpty) return start(la, lo);
    if (lat.last == la && lon.last == lo) return;
    lat.add(la);
    lon.add(lo);
    way.add(w);
    dir.add(d);
    edge.add(e);
  }
}

/// Places [n] stops on the polyline by a monotone Viterbi: each stop offers the
/// path positions within reach, the chain minimises the summed distance and may
/// never move backwards. Returns the metre offset of each stop along the path.
List<double> placeStops(List<double> vLat, List<double> vLon,
    List<double> sLat, List<double> sLon) {
  final nv = vLat.length;
  final arc = List<double>.filled(nv, 0);
  for (var i = 1; i < nv; i++) {
    arc[i] = arc[i - 1] +
        haversineMetres(vLat[i - 1], vLon[i - 1], vLat[i], vLon[i]);
  }
  final n = sLat.length;
  if (nv < 2) return List<double>.filled(n, 0);

  final candPos = <List<double>>[], candDist = <List<double>>[];
  for (var s = 0; s < n; s++) {
    final cosLat = math.cos(sLat[s] * math.pi / 180);
    final pos = <double>[], dist = <double>[];
    var bestD = double.infinity, bestPos = 0.0;
    for (var i = 0; i + 1 < nv; i++) {
      final ay = vLat[i], by = vLat[i + 1];
      if (sLat[s] < math.min(ay, by) - 0.0007 ||
          sLat[s] > math.max(ay, by) + 0.0007) {
        continue;
      }
      final ax = vLon[i] * cosLat, bx = vLon[i + 1] * cosLat;
      final px = sLon[s] * cosLat;
      if (px < math.min(ax, bx) - 0.0007 || px > math.max(ax, bx) + 0.0007) {
        continue;
      }
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0
          ? 0.0
          : (((px - ax) * dx + (sLat[s] - ay) * dy) / len2).clamp(0.0, 1.0);
      final my = (sLat[s] - (ay + dy * t)) * 111320;
      final mx = (px - (ax + dx * t)) * 111320;
      final d = math.sqrt(my * my + mx * mx);
      final p = arc[i] + (arc[i + 1] - arc[i]) * t;
      pos.add(p);
      dist.add(d);
      if (d < bestD) {
        bestD = d;
        bestPos = p;
      }
    }
    if (pos.isEmpty) {
      // Far from the path (a stop the route only passes at a distance): the
      // nearest vertex still gives a sane, monotone place.
      var bi = 0;
      var bd = double.infinity;
      for (var i = 0; i < nv; i++) {
        final d = haversineMetres(sLat[s], sLon[s], vLat[i], vLon[i]);
        if (d < bd) {
          bd = d;
          bi = i;
        }
      }
      candPos.add([arc[bi]]);
      candDist.add([bd]);
      continue;
    }
    // Keep local minima: one candidate per 30 m stretch, the nearest, and only
    // those not much worse than the best.
    final order = [for (var i = 0; i < pos.length; i++) i]
      ..sort((a, b) => pos[a].compareTo(pos[b]));
    final keepPos = <double>[], keepDist = <double>[];
    final limit = math.max(50.0, bestD + 25);
    for (final i in order) {
      if (dist[i] > limit) continue;
      if (keepPos.isNotEmpty && pos[i] - keepPos.last < 30) {
        if (dist[i] < keepDist.last) {
          keepPos[keepPos.length - 1] = pos[i];
          keepDist[keepDist.length - 1] = dist[i];
        }
      } else {
        keepPos.add(pos[i]);
        keepDist.add(dist[i]);
      }
    }
    if (keepPos.isEmpty) {
      keepPos.add(bestPos);
      keepDist.add(bestD);
    }
    candPos.add(keepPos);
    candDist.add(keepDist);
  }

  // Viterbi: cost[j] over the current stop's candidates.
  var cost = List<double>.from(candDist[0]);
  final back = <List<int>>[<int>[]];
  for (var s = 1; s < n; s++) {
    final next = List<double>.filled(candPos[s].length, double.infinity);
    final bp = List<int>.filled(candPos[s].length, 0);
    for (var c = 0; c < candPos[s].length; c++) {
      for (var p = 0; p < candPos[s - 1].length; p++) {
        final back0 = candPos[s - 1][p] - candPos[s][c];
        // Moving backwards is allowed only as a last resort, at a price that
        // outweighs any distance.
        final penalty = back0 > 0.5 ? 1e6 + back0 : 0.0;
        final v = cost[p] + candDist[s][c] + penalty;
        if (v < next[c]) {
          next[c] = v;
          bp[c] = p;
        }
      }
    }
    cost = next;
    back.add(bp);
  }
  var c = 0;
  for (var i = 1; i < cost.length; i++) {
    if (cost[i] < cost[c]) c = i;
  }
  final out = List<double>.filled(n, 0);
  for (var s = n - 1; s >= 0; s--) {
    out[s] = candPos[s][c];
    if (s > 0) c = back[s][c];
  }
  // Last resort clamp: offsets never decrease.
  for (var s = 1; s < n; s++) {
    if (out[s] < out[s - 1]) out[s] = out[s - 1];
  }
  return out;
}

/// Closes a path: places the stops, inserts a vertex at each stop's place and
/// derives the per-hop approximate flags. [stopLat]/[stopLon] are the stops in
/// pattern order.
SnappedPattern finishPath(int pattern, PathBuilder path, List<double> stopLat,
    List<double> stopLon) {
  final nv = path.lat.length;
  final n = stopLat.length;
  final offsets = placeStops(path.lat, path.lon, stopLat, stopLon);

  final arc = List<double>.filled(nv, 0);
  for (var i = 1; i < nv; i++) {
    arc[i] = arc[i - 1] +
        haversineMetres(path.lat[i - 1], path.lon[i - 1], path.lat[i], path.lon[i]);
  }

  final lat = <double>[], lon = <double>[];
  final way = <int>[], dir = <int>[], edge = <int>[];
  final stopVertex = List<int>.filled(n, 0);
  var s = 0;
  void push(int i, double la, double lo) {
    lat.add(la);
    lon.add(lo);
    way.add(path.way[i]);
    dir.add(path.dir[i]);
    edge.add(path.edge[i]);
  }

  for (var i = 0; i < nv; i++) {
    push(i, path.lat[i], path.lon[i]);
    // Stops sitting on vertex i itself.
    while (s < n && offsets[s] <= arc[i] + 0.5) {
      stopVertex[s++] = lat.length - 1;
    }
    if (i + 1 >= nv) break;
    // Stops strictly inside segment i -> i+1 get a vertex of their own, with
    // the segment's attributes.
    while (s < n && offsets[s] < arc[i + 1] - 0.5) {
      final f = (offsets[s] - arc[i]) / (arc[i + 1] - arc[i]);
      push(i + 1, path.lat[i] + (path.lat[i + 1] - path.lat[i]) * f,
          path.lon[i] + (path.lon[i + 1] - path.lon[i]) * f);
      stopVertex[s++] = lat.length - 1;
    }
  }
  while (s < n) {
    stopVertex[s++] = lat.length - 1;
  }

  if (edge.length > 1) edge[0] = edge[1]; // vertex 0 has no segment of its own

  final hopApprox = Uint8List(math.max(0, n - 1));
  for (var h = 0; h + 1 < n; h++) {
    for (var v = stopVertex[h] + 1; v <= stopVertex[h + 1]; v++) {
      if (edge[v] == edgeApprox) {
        hopApprox[h] = 1;
        break;
      }
    }
  }
  return SnappedPattern(
    pattern: pattern,
    vertexLat: Int32List.fromList([for (final v in lat) microdeg(v)]),
    vertexLon: Int32List.fromList([for (final v in lon) microdeg(v)]),
    vertexWay: Int64List.fromList(way),
    vertexDir: Uint8List.fromList(dir),
    stopVertex: Int32List.fromList(stopVertex),
    stopLat: Int32List.fromList([for (final i in stopVertex) microdeg(lat[i])]),
    stopLon: Int32List.fromList([for (final i in stopVertex) microdeg(lon[i])]),
    hopApprox: hopApprox,
    vertexEdge: Int32List.fromList(edge),
  );
}

/// Geometry for a pattern that is not matched to roads (metro, funicular: own
/// rails, no OSM graph): the GTFS shape as published. Without a shape the stop
/// chain is used and marked approximate.
SnappedPattern snapShapeOnly(int pattern, List<double> stopLat,
    List<double> stopLon, ShapePolyline? shape,
    {bool approximate = false}) {
  final path = PathBuilder();
  if (shape == null) {
    for (var i = 0; i < stopLat.length; i++) {
      path.add(stopLat[i], stopLon[i], -1, 0, edgeApprox);
    }
  } else {
    for (var i = 0; i < shape.lat.length; i++) {
      path.add(shape.lat[i], shape.lon[i], -1, 0,
          approximate ? edgeApprox : edgeShape);
    }
  }
  return finishPath(pattern, path, stopLat, stopLon);
}
