/// 9.3 — snapping a GTFS pattern onto the directed road/tram graph.
///
/// Stops snap to an **edge**, not a node, so a stop lands on the carriageway
/// the pattern actually uses. Each hop is routed in the pattern's own
/// direction; a hop that cannot be routed inside its cap, or that strays from
/// the GTFS shape, becomes a straight chord flagged approximate **for that hop
/// only**.
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'distance.dart';
import 'road_graph.dart';

const stopSnapRadiusMetres = 40.0;
/// Last resort for stops set back from the road (rural laybys, squares).
const wideSnapRadiusMetres = 80.0;
const headingPenaltyMetres = 60.0;
const corridorFreeMetres = 25.0;
const offShapeLimitMetres = 60.0;

/// Second-chance corridor: a hop that strayed is re-routed hugging the shape.
const tightCorridorMetres = 8.0;
const serviceTerminusMetres = 100.0;
const serviceCostFactor = 3.0;

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

/// One pattern's geometry on the graph.
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
  });

  final int pattern;

  /// Microdegrees.
  final Int32List vertexLat, vertexLon;

  /// OSM way of the edge **leading into** each vertex; -1 for vertex 0 and for
  /// chord vertices. `vertexDir[i] != 0` means that edge runs against the
  /// way's own point order.
  final Int64List vertexWay;
  final Uint8List vertexDir;

  /// Vertex index at which each stop sits — slice by index, never by search.
  final Int32List stopVertex;

  /// Snapped stop coordinates, microdegrees.
  final Int32List stopLat, stopLon;

  /// One flag per hop (stop i -> i+1); 1 = straight chord, approximate.
  final Uint8List hopApprox;

  int get vertexCount => vertexLat.length;
  int get approxHops => hopApprox.where((f) => f != 0).length;
}

class _Snap {
  _Snap(this.edge, this.fraction, this.lat, this.lon);
  final int edge; // -1: not snapped, raw stop coordinate
  final double fraction;
  final double lat, lon;
}

class _Hop {
  _Hop(this.lat, this.lon, this.way, this.dir, this.length);
  final List<double> lat, lon;
  final List<int> way;
  final List<int> dir;
  final double length;
}

/// Min-heap over (cost, edge-state).
class _Heap {
  final _cost = <double>[];
  final _item = <int>[];

  bool get isEmpty => _cost.isEmpty;

  void push(double cost, int item) {
    _cost.add(cost);
    _item.add(item);
    var i = _cost.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_cost[p] <= _cost[i]) break;
      _swap(p, i);
      i = p;
    }
  }

  (double, int) pop() {
    final top = (_cost[0], _item[0]);
    final last = _cost.length - 1;
    _swap(0, last);
    _cost.removeLast();
    _item.removeLast();
    var i = 0;
    while (true) {
      final l = 2 * i + 1, r = l + 1;
      var small = i;
      if (l < _cost.length && _cost[l] < _cost[small]) small = l;
      if (r < _cost.length && _cost[r] < _cost[small]) small = r;
      if (small == i) break;
      _swap(i, small);
      i = small;
    }
    return top;
  }

  void _swap(int a, int b) {
    final c = _cost[a];
    _cost[a] = _cost[b];
    _cost[b] = c;
    final it = _item[a];
    _item[a] = _item[b];
    _item[b] = it;
  }
}

class PatternSnapper {
  PatternSnapper(this.graph);

  final RoadGraph graph;
  final _hopCache = HashMap<String, _Hop?>();

  int cacheHits = 0;
  int cacheMisses = 0;

  /// Why hops became chords, for `tool/lines_report.dart`.
  int chordUnsnappedStop = 0, chordNoRoute = 0, chordOffShape = 0;
  int failExhausted = 0, failCap = 0, failSettled = 0;
  final deviationBuckets = List<int>.filled(4, 0);



  /// Snaps one pattern. [stopLat]/[stopLon] are the pattern's stops in order.
  SnappedPattern snap({
    required int pattern,
    required Float64List stopLat,
    required Float64List stopLon,
    ShapePolyline? shape,
  }) {
    final n = stopLat.length;
    final snaps = <_Snap>[];
    for (var i = 0; i < n; i++) {
      final aheadOf = i + 1 < n ? i + 1 : i - 1;
      final bearing = bearingBetween(
          stopLat[i], stopLon[i], stopLat[aheadOf], stopLon[aheadOf]);
      snaps.add(_snapStop(stopLat[i], stopLon[i],
          i + 1 < n ? bearing : (bearing + 180) % 360, shape));
    }

    final terminusLat = <double>[stopLat.first, stopLat.last];
    final terminusLon = <double>[stopLon.first, stopLon.last];

    final vLat = <double>[snaps[0].lat];
    final vLon = <double>[snaps[0].lon];
    final vWay = <int>[-1];
    final vDir = <int>[0];
    final stopVertex = <int>[0];
    final approx = Uint8List(math.max(0, n - 1));

    for (var i = 0; i + 1 < n; i++) {
      final a = snaps[i], b = snaps[i + 1];
      final straight = haversineMetres(a.lat, a.lon, b.lat, b.lon);
      final cap = math.max(2500.0, straight * 1.8);
      _Hop? hop;
      if (a.edge < 0 || b.edge < 0) {
        chordUnsnappedStop++;
      } else {
        hop = _routeCached(a, b, shape, cap, terminusLat, terminusLon);
        if (hop == null) {
          chordNoRoute++;
        } else if (shape != null && _offShape(hop, shape)) {
          // Routed, but away from the corridor: pull the route onto the shape
          // hard and try once more before giving up on the hop.
          hop = _route(a, b, shape, cap, terminusLat, terminusLon,
              corridorFree: tightCorridorMetres);
          if (hop == null || _offShape(hop, shape)) {
            hop = null;
            chordOffShape++;
          }
        }
      }
      if (hop == null) {
        approx[i] = 1;
        vLat.add(b.lat);
        vLon.add(b.lon);
        vWay.add(-1);
        vDir.add(0);
      } else {
        for (var k = 1; k < hop.lat.length; k++) {
          vLat.add(hop.lat[k]);
          vLon.add(hop.lon[k]);
          vWay.add(hop.way[k]);
          vDir.add(hop.dir[k]);
        }
      }
      stopVertex.add(vLat.length - 1);
    }

    return SnappedPattern(
      pattern: pattern,
      vertexLat: Int32List.fromList([for (final v in vLat) microdeg(v)]),
      vertexLon: Int32List.fromList([for (final v in vLon) microdeg(v)]),
      vertexWay: Int64List.fromList(vWay),
      vertexDir: Uint8List.fromList(vDir),
      stopVertex: Int32List.fromList(stopVertex),
      stopLat: Int32List.fromList([for (final s in snaps) microdeg(s.lat)]),
      stopLon: Int32List.fromList([for (final s in snaps) microdeg(s.lon)]),
      hopApprox: approx,
    );
  }

  _Snap _snapStop(
      double lat, double lon, double bearing, ShapePolyline? shape) {
    var hits = graph.near(lat, lon, stopSnapRadiusMetres);
    if (hits.isEmpty) hits = graph.near(lat, lon, wideSnapRadiusMetres);
    // Only edges that run **in the pattern's direction of travel** are
    // candidates: an edge pointing the other way is the opposite carriageway,
    // and a hop starting there can only be routed by an impossible loop. The
    // heading penalty then picks between the ones that do.
    // Service ways are for terminus turnarounds only: a stop that snaps to one
    // leaves the hop unroutable, because routing will not use them mid-route.
    final road = [for (final h in hits) if (!graph.isService(h.edge)) h];
    var best = _bestOf(road, bearing, 90, shape);
    best ??= _bestOf(road, bearing, 180, shape);
    best ??= _bestOf(hits, bearing, 180, shape);
    if (best == null) return _Snap(-1, 0, lat, lon);
    return _Snap(best.edge, best.fraction, best.lat, best.lon);
  }

  EdgeHit? _bestOf(
      List<EdgeHit> hits, double bearing, double maxDelta, ShapePolyline? shape) {
    var bestScore = double.infinity;
    EdgeHit? best;
    for (final h in hits) {
      final delta = bearingDelta(graph.bearingOf(h.edge), bearing);
      if (delta > maxDelta) continue;
      // Distance to the GTFS shape decides which carriageway or side lane the
      // stop belongs to; heading alone cannot tell them apart.
      final offShape = shape == null ? 0.0 : shape.distanceTo(h.lat, h.lon);
      final score = h.metres + headingPenaltyMetres * delta / 180 + offShape;
      if (score < bestScore) {
        bestScore = score;
        best = h;
      }
    }
    return best;
  }

  /// Largest distance of any hop vertex from the shape, metres.
  double _shapeDeviation(_Hop hop, ShapePolyline shape) {
    var worst = 0.0;
    for (var i = 0; i < hop.lat.length; i++) {
      final d = shape.distanceTo(hop.lat[i], hop.lon[i]);
      if (d > worst) worst = d;
    }
    return worst;
  }

  bool _offShape(_Hop hop, ShapePolyline shape) {
    final d = _shapeDeviation(hop, shape);
    if (d > offShapeLimitMetres) {
      deviationBuckets[d < 100
          ? 0
          : d < 200
              ? 1
              : d < 500
                  ? 2
                  : 3]++;
      return true;
    }
    return false;
  }

  _Hop? _routeCached(_Snap a, _Snap b, ShapePolyline? shape, double cap,
      List<double> terminusLat, List<double> terminusLon) {
    final key = '${a.edge}:${a.fraction.toStringAsFixed(3)}>'
        '${b.edge}:${b.fraction.toStringAsFixed(3)}';
    if (_hopCache.containsKey(key)) {
      final cached = _hopCache[key];
      cacheHits++;
      if (cached == null) return null;
      if (shape == null || !_offShape(cached, shape)) return cached;
      // Shared hop, different corridor: route it again for this pattern only.
      return _route(a, b, shape, cap, terminusLat, terminusLon);
    }
    cacheMisses++;
    final hop = _route(a, b, shape, cap, terminusLat, terminusLon);
    _hopCache[key] = hop;
    return hop;
  }

  /// Dijkstra/A* over **edge states**, so an immediate U-turn on the same way
  /// can be forbidden.
  _Hop? _route(_Snap a, _Snap b, ShapePolyline? shape, double cap,
      List<double> terminusLat, List<double> terminusLon,
      {double corridorFree = corridorFreeMetres}) {
    if (a.edge == b.edge && a.fraction <= b.fraction) {
      final len = graph.edgeLen[a.edge] * (b.fraction - a.fraction);
      return _Hop([a.lat, b.lat], [a.lon, b.lon],
          [-1, graph.edgeWay[a.edge]], [0, graph.isReversed(a.edge) ? 1 : 0], len);
    }

    final targetNode = graph.edgeFrom[b.edge];
    final tailLen = graph.edgeLen[b.edge] * b.fraction;

    final dist = HashMap<int, double>();
    final prev = HashMap<int, int>();
    final real = HashMap<int, double>();
    final heap = _Heap();

    final startNode = graph.edgeTo[a.edge];
    final headLen = graph.edgeLen[a.edge] * (1 - a.fraction);
    dist[a.edge] = headLen * _factor(a.edge, shape, corridorFree);
    real[a.edge] = headLen;
    heap.push(dist[a.edge]! + _heuristic(startNode, targetNode), a.edge);

    final done = <int>{};
    int? finalEdge;
    while (!heap.isEmpty) {
      final (_, edge) = heap.pop();
      if (!done.add(edge)) continue;
      final node = graph.edgeTo[edge];
      if (node == targetNode) {
        finalEdge = edge;
        break;
      }
      final soFar = real[edge]!;
      if (soFar > cap) continue;
      for (final next in graph.edgesFrom(node)) {
        if (next == b.edge) continue; // reached through targetNode instead
        // No immediate U-turn on the same way, except at a terminus.
        if (graph.edgeWay[next] == graph.edgeWay[edge] &&
            graph.edgeTo[next] == graph.edgeFrom[edge]) {
          continue;
        }
        if (graph.isService(next) &&
            !_nearTerminus(next, terminusLat, terminusLon)) {
          continue;
        }
        final len = graph.edgeLen[next];
        final cost = dist[edge]! + len * _factor(next, shape, corridorFree);
        if (cost >= (dist[next] ?? double.infinity)) continue;
        dist[next] = cost;
        real[next] = soFar + len;
        prev[next] = edge;
        heap.push(cost + _heuristic(graph.edgeTo[next], targetNode), next);
      }
    }
    if (finalEdge == null) {
      failExhausted++;
      failSettled += done.length;
      return null;
    }
    if (real[finalEdge]! + tailLen > cap) {
      failCap++;
      return null;
    }

    final chain = <int>[];
    for (int? e = finalEdge; e != null; e = prev[e]) {
      chain.add(e);
    }
    final lat = <double>[a.lat], lon = <double>[a.lon];
    final way = <int>[-1], dir = <int>[0];
    for (var i = chain.length - 1; i >= 0; i--) {
      final e = chain[i];
      final node = graph.edgeTo[e];
      lat.add(graph.nodeLat[node]);
      lon.add(graph.nodeLon[node]);
      way.add(graph.edgeWay[e]);
      dir.add(graph.isReversed(e) ? 1 : 0);
    }
    lat.add(b.lat);
    lon.add(b.lon);
    way.add(graph.edgeWay[b.edge]);
    dir.add(graph.isReversed(b.edge) ? 1 : 0);
    return _Hop(lat, lon, way, dir, real[finalEdge]! + tailLen);
  }

  double _heuristic(int node, int target) => haversineMetres(graph.nodeLat[node],
      graph.nodeLon[node], graph.nodeLat[target], graph.nodeLon[target]);

  double _factor(int edge, ShapePolyline? shape, double corridorFree) {
    var f = 1.0;
    if (shape != null) {
      final midLat = (graph.nodeLat[graph.edgeFrom[edge]] +
              graph.nodeLat[graph.edgeTo[edge]]) /
          2;
      final midLon = (graph.nodeLon[graph.edgeFrom[edge]] +
              graph.nodeLon[graph.edgeTo[edge]]) /
          2;
      final d = shape.distanceTo(midLat, midLon);
      f = 1 + math.max(0.0, d - corridorFree) / corridorFree;
    }
    if (graph.isService(edge)) f *= serviceCostFactor;
    return f;
  }

  bool _nearTerminus(int edge, List<double> lat, List<double> lon) {
    for (var i = 0; i < lat.length; i++) {
      if (graph.distanceToEdge(edge, lat[i], lon[i]) <= serviceTerminusMetres) {
        return true;
      }
    }
    return false;
  }
}
