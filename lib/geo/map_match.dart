/// Map matching of a whole GTFS pattern onto the directed road/tram graph
/// (§9.3): a hidden Markov model over the pattern's own GTFS shape.
///
/// The shape is the evidence of where the vehicle really drove. It is sampled
/// every [sampleStepMetres]; each sample offers the graph edges within
/// [matchRadiusMetres] as candidates (cost: distance to the road and heading
/// against the shape's direction); moving between consecutive samples costs the
/// mismatch between the graph route and the shape's own arc length. Viterbi
/// then yields the one consistent edge sequence for the **whole pattern**, so
/// consecutive stops can never disagree about the road, and there is no
/// per-hop routing to zig-zag, spur at stops or jump to a parallel street.
///
/// Failure ladder for a stretch the model cannot match: (1) retry candidates at
/// [wideMatchRadiusMetres]; (2) bridge the gap with a shortest path that hugs
/// the shape ([bridgeCorridorMetres]); (3) keep the shape's own polyline for
/// that stretch, marked approximate (dotted).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'distance.dart';
import 'pattern_snap.dart';
import 'road_graph.dart';

const sampleStepMetres = 15.0;
const matchRadiusMetres = 35.0;
const wideMatchRadiusMetres = 70.0;
const emissionSigmaMetres = 10.0;
const headingWeight = 3.0;
const serviceEdgePenalty = 1.0;

/// Tram track inside the bus graph: usable, never preferred to a road.
const railEdgePenalty = 2.0;

/// Against the flow of a one-way street: only when the shape insists.
const contraflowPenalty = 3.0;
const maxCandidates = 8;
const transitionBetaMetres = 3.0;
const uTurnPenalty = 6.0;
const bridgeCorridorMetres = 40.0;
const corridorFreeMetres = 15.0;
const spurMaxMetres = 60.0;
const stopChainSnapMetres = 40.0;

/// Min-heap over (cost, item).
class _Heap {
  final _cost = <double>[];
  final _item = <int>[];

  bool get isEmpty => _cost.isEmpty;

  void clear() {
    _cost.clear();
    _item.clear();
  }

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


/// Bounded Dijkstra over graph nodes with reusable scratch arrays.
class _Search {
  _Search(this.g)
      : dist = Float64List(g.nodeCount),
        via = Int32List(g.nodeCount),
        stamp = Int32List(g.nodeCount);

  final RoadGraph g;
  final Float64List dist;
  final Int32List via;
  final Int32List stamp;
  final _heap = _Heap();
  int _gen = 0;
  int source = -1;

  /// Explores from [src] up to cost [limit]; stops early at [target]. With a
  /// [corridor] each edge costs length x a factor that grows with its distance
  /// from the shape, so the route hugs the shape.
  void run(int src, double limit, {int target = -1, ShapePolyline? corridor}) {
    _gen++;
    source = src;
    _heap.clear();
    stamp[src] = _gen;
    dist[src] = 0;
    via[src] = -1;
    _heap.push(0, src);
    while (!_heap.isEmpty) {
      final (d, n) = _heap.pop();
      if (d > dist[n]) continue;
      if (n == target) return;
      for (final e in g.edgesFrom(n)) {
        var c = d + g.edgeLen[e];
        if (corridor != null) {
          final a = g.edgeFrom[e], b = g.edgeTo[e];
          final off = corridor.distanceTo(
              (g.nodeLat[a] + g.nodeLat[b]) / 2, (g.nodeLon[a] + g.nodeLon[b]) / 2);
          c = d +
              g.edgeLen[e] *
                  (1 + math.max(0.0, off - corridorFreeMetres) / corridorFreeMetres);
        }
        if (c > limit) continue;
        final m = g.edgeTo[e];
        if (stamp[m] != _gen || c < dist[m]) {
          stamp[m] = _gen;
          dist[m] = c;
          via[m] = e;
          _heap.push(c, m);
        }
      }
    }
  }

  double distTo(int node) => stamp[node] == _gen ? dist[node] : double.infinity;

  /// Edges from the last run's source to [node], in travel order.
  List<int> pathTo(int node) {
    final out = <int>[];
    var n = node;
    while (n != source) {
      final e = via[n];
      out.add(e);
      n = g.edgeFrom[e];
    }
    return out.reversed.toList();
  }
}

class _Cand {
  const _Cand(this.edge, this.t, this.emit);
  final int edge;
  final double t;
  final double emit;
}

class _Run {
  _Run(this.first, this.last, this.chosen);
  int first, last;
  final List<_Cand> chosen;
  List<int> edges = [];
}

/// Why matching fell short, for the build report.
class MatchStats {
  int patterns = 0, samples = 0, unmatchedSamples = 0;
  int runs = 0, bridged = 0, approxGaps = 0, wideRetries = 0, spursRemoved = 0;
  double approxMetres = 0;
  final gapCause = <String, int>{};

  /// One line per dotted stretch: `pattern lat lon metres cause`.
  final gaps = <String>[];
  void cause(String c) => gapCause.update(c, (v) => v + 1, ifAbsent: () => 1);
}

class PatternSnapper {
  PatternSnapper(this.graph) : _search = _Search(graph);

  final RoadGraph graph;
  final _Search _search;
  final stats = MatchStats();
  int _pattern = -1;

  /// Matches one pattern. [stopLat]/[stopLon] are its stops in order; [shape]
  /// is its GTFS shape (null: the stops are routed hop by hop instead).
  SnappedPattern snap({
    required int pattern,
    required Float64List stopLat,
    required Float64List stopLon,
    ShapePolyline? shape,
  }) {
    stats.patterns++;
    _pattern = pattern;
    final path = shape != null && shape.lat.length >= 2
        ? _matchShape(shape)
        : _routeStopChain(stopLat, stopLon);
    return finishPath(pattern, path, stopLat, stopLon);
  }

  // ---------------------------------------------------------------- shape

  PathBuilder _matchShape(ShapePolyline shape) {
    final lat = <double>[], lon = <double>[], arc = <double>[];
    _resample(shape, lat, lon, arc);
    final n = lat.length;
    stats.samples += n;

    final heading = List<double>.generate(n, (k) {
      final a = math.max(0, k - 1), b = math.min(n - 1, k + 1);
      return bearingBetween(lat[a], lon[a], lat[b], lon[b]);
    });
    final cands = List<List<_Cand>>.generate(n, (k) {
      var c = _candidates(lat[k], lon[k], heading[k], matchRadiusMetres);
      if (c.isEmpty) {
        c = _candidates(lat[k], lon[k], heading[k], wideMatchRadiusMetres,
            besideOnly: true);
        if (c.isNotEmpty) stats.wideRetries++;
      }
      return c;
    });
    stats.unmatchedSamples += cands.where((c) => c.isEmpty).length;

    final runs = _viterbi(cands, arc);
    for (final r in runs) {
      _edgesOfRun(r, arc);
    }
    stats.runs += runs.length;

    // The pattern's own ends: a first or last edge the shape barely touches is
    // not part of the route.
    if (runs.isNotEmpty) {
      final f = runs.first, l = runs.last;
      if (f.edges.length > 1 && f.chosen.first.t >= 0.5) f.edges.removeAt(0);
      if (l.edges.length > 1 && l.chosen.last.t <= 0.5) l.edges.removeLast();
    }

    final path = PathBuilder();
    if (runs.isEmpty) {
      stats.cause('no candidates');
      _approxSpan(path, lat, lon, 0, n - 1, arc, 'no candidates');
      return path;
    }
    if (runs.first.first > 0) {
      stats.cause('leading unmatched');
      _approxSpan(path, lat, lon, 0, runs.first.first - 1, arc, 'leading unmatched');
    }
    for (var i = 0; i < runs.length; i++) {
      final r = runs[i];
      if (i > 0) {
        final prev = runs[i - 1];
        _gap(path, prev, r, shape, lat, lon, arc);
      }
      _addEdges(path, r.edges);
    }
    if (runs.last.last < n - 1) {
      stats.cause('trailing unmatched');
      _approxSpan(path, lat, lon, runs.last.last + 1, n - 1, arc, 'trailing unmatched');
    }
    return _collapseSpurs(path);
  }

  void _resample(ShapePolyline shape, List<double> lat, List<double> lon,
      List<double> arc) {
    lat.add(shape.lat[0]);
    lon.add(shape.lon[0]);
    arc.add(0);
    var total = 0.0, next = sampleStepMetres;
    for (var i = 0; i + 1 < shape.lat.length; i++) {
      final d = haversineMetres(
          shape.lat[i], shape.lon[i], shape.lat[i + 1], shape.lon[i + 1]);
      if (d == 0) continue;
      while (next <= total + d) {
        final f = (next - total) / d;
        lat.add(shape.lat[i] + (shape.lat[i + 1] - shape.lat[i]) * f);
        lon.add(shape.lon[i] + (shape.lon[i + 1] - shape.lon[i]) * f);
        arc.add(next);
        next += sampleStepMetres;
      }
      total += d;
    }
    if (total - arc.last > 1) {
      lat.add(shape.lat.last);
      lon.add(shape.lon.last);
      arc.add(total);
    }
  }

  /// [besideOnly]: keep only edges the sample projects strictly inside of.
  /// The wide retry uses it, so a road that merely ends near the shape does not
  /// claim samples beyond its end.
  List<_Cand> _candidates(double lat, double lon, double heading, double radius,
      {bool besideOnly = false}) {
    final out = <_Cand>[];
    for (final h in graph.near(lat, lon, radius)) {
      if (besideOnly && (h.fraction <= 0 || h.fraction >= 1)) continue;
      final delta = bearingDelta(graph.bearingOf(h.edge), heading);
      final d = h.metres / emissionSigmaMetres;
      final emit = 0.5 * d * d +
          headingWeight * (delta / 90) * (delta / 90) +
          (graph.isService(h.edge) ? serviceEdgePenalty : 0) +
          (graph.mode == GraphMode.bus && graph.isRail(h.edge) ? railEdgePenalty : 0) +
          (graph.isContraflow(h.edge) ? contraflowPenalty : 0);
      out.add(_Cand(h.edge, h.fraction, emit));
    }
    out.sort((a, b) => a.emit.compareTo(b.emit));
    return out.length > maxCandidates ? out.sublist(0, maxCandidates) : out;
  }

  /// Bound for the graph route between two samples [gc] metres apart.
  double _limit(double gc) => 2 * gc + 50;

  /// Route length from candidate [a] to [b] with [_search] already run from
  /// the end node of a's edge; infinity when unreachable.
  double _routeLen(_Cand a, _Cand b) {
    final la = graph.edgeLen[a.edge], lb = graph.edgeLen[b.edge];
    if (a.edge == b.edge) {
      if (b.t >= a.t) return (b.t - a.t) * la;
      if ((a.t - b.t) * la <= 3) return 0; // projection jitter, not a loop
    }
    final d = _search.distTo(graph.edgeFrom[b.edge]);
    if (d.isInfinite) return d;
    return (1 - a.t) * la + d + b.t * lb;
  }

  bool _isReverse(int a, int b) =>
      graph.edgeFrom[a] == graph.edgeTo[b] && graph.edgeTo[a] == graph.edgeFrom[b];

  /// Reverse in place rather than in node id: OSM sometimes carries two nodes
  /// a few centimetres apart, and the there-and-back between them is still a
  /// spur.
  bool _isReverseGeom(int a, int b) {
    if (_isReverse(a, b)) return true;
    bool same(int n, int m) =>
        (graph.nodeLat[n] - graph.nodeLat[m]).abs() < 4e-6 &&
        (graph.nodeLon[n] - graph.nodeLon[m]).abs() < 6e-6;
    return same(graph.edgeFrom[a], graph.edgeTo[b]) &&
        same(graph.edgeTo[a], graph.edgeFrom[b]) &&
        bearingDelta(graph.bearingOf(a), graph.bearingOf(b)) > 150;
  }

  List<_Run> _viterbi(List<List<_Cand>> cands, List<double> arc) {
    final n = cands.length;
    final runs = <_Run>[];
    var open = false;
    var start = 0;
    var cost = <double>[];
    final back = List<Int32List?>.filled(n, null);

    void close(int last) {
      var c = 0;
      for (var i = 1; i < cost.length; i++) {
        if (cost[i] < cost[c]) c = i;
      }
      final chosen = List<_Cand?>.filled(last - start + 1, null);
      for (var k = last; k >= start; k--) {
        chosen[k - start] = cands[k][c];
        if (k > start) c = back[k]![c];
      }
      runs.add(_Run(start, last, [for (final x in chosen) x!]));
      open = false;
    }

    for (var i = 0; i < n; i++) {
      final ci = cands[i];
      if (ci.isEmpty) {
        if (open) close(i - 1);
        continue;
      }
      if (!open) {
        open = true;
        start = i;
        cost = [for (final c in ci) c.emit];
        continue;
      }
      final prev = cands[i - 1];
      final gc = arc[i] - arc[i - 1];
      final limit = _limit(gc);
      final next = List<double>.filled(ci.length, double.infinity);
      final bp = Int32List(ci.length);
      // Candidates sharing an end node share one search.
      final order = [for (var k = 0; k < prev.length; k++) k]
        ..sort((a, b) => graph.edgeTo[prev[a].edge].compareTo(graph.edgeTo[prev[b].edge]));
      var searched = -1;
      for (final p in order) {
        if (cost[p].isInfinite) continue;
        final node = graph.edgeTo[prev[p].edge];
        if (node != searched) {
          _search.run(node, limit);
          searched = node;
        }
        for (var c = 0; c < ci.length; c++) {
          final r = _routeLen(prev[p], ci[c]);
          if (r.isInfinite) continue;
          final v = cost[p] +
              (r - gc).abs() / transitionBetaMetres +
              (_isReverse(prev[p].edge, ci[c].edge) ? uTurnPenalty : 0) +
              ci[c].emit;
          if (v < next[c]) {
            next[c] = v;
            bp[c] = p;
          }
        }
      }
      if (next.every((v) => v.isInfinite)) {
        close(i - 1);
        open = true;
        start = i;
        cost = [for (final c in ci) c.emit];
        continue;
      }
      cost = next;
      back[i] = bp;
    }
    if (open) close(n - 1);
    return runs;
  }

  /// Samples that project onto the very end of a run's last edge (or the very
  /// start of its first) are beyond the road, not on it: they are handed back
  /// to the gap so the dotted stretch starts where the road ends.
  void _trimOvershoot(_Run r) {
    var end = r.chosen.length - 1;
    while (end > 0 &&
        r.chosen[end].edge == r.chosen[end - 1].edge &&
        r.chosen[end].t >= 0.9999 &&
        r.chosen[end - 1].t >= 0.9999) {
      end--;
    }
    var start = 0;
    while (start < end &&
        r.chosen[start].edge == r.chosen[start + 1].edge &&
        r.chosen[start].t <= 0.0001 &&
        r.chosen[start + 1].t <= 0.0001) {
      start++;
    }
    if (start > 0 || end < r.chosen.length - 1) {
      final kept = r.chosen.sublist(start, end + 1);
      r.chosen
        ..clear()
        ..addAll(kept);
      r.last = r.first + end;
      r.first += start;
    }
  }

  /// The edge sequence of a run: candidate edges joined by the graph routes
  /// the model itself costed.
  void _edgesOfRun(_Run r, List<double> arc) {
    _trimOvershoot(r);
    final edges = <int>[r.chosen.first.edge];
    for (var k = 1; k < r.chosen.length; k++) {
      final a = r.chosen[k - 1], b = r.chosen[k];
      if (a.edge == b.edge &&
          (b.t >= a.t || (a.t - b.t) * graph.edgeLen[a.edge] <= 3)) {
        continue;
      }
      final gc = arc[r.first + k] - arc[r.first + k - 1];
      _search.run(graph.edgeTo[a.edge], _limit(gc), target: graph.edgeFrom[b.edge]);
      if (_search.distTo(graph.edgeFrom[b.edge]).isFinite) {
        edges.addAll(_search.pathTo(graph.edgeFrom[b.edge]));
      }
      edges.add(b.edge);
    }
    r.edges = edges;
  }

  /// Removes there-and-back stubs from a finished path: a segment immediately
  /// followed by its own reverse, cascading inward, while the stub stays under
  /// [spurMaxMetres]. Longer excursions are real turnarounds and stay. Working
  /// on the whole path also catches stubs at the joins between runs.
  PathBuilder _collapseSpurs(PathBuilder path) {
    final n = path.lat.length;
    // Segment i (1..n-1) leads into vertex i; keep[] marks the survivors.
    final stack = <int>[];
    var acc = 0.0;
    for (var i = 1; i < n; i++) {
      final e = path.edge[i];
      if (e >= 0 && stack.isNotEmpty && path.edge[stack.last] >= 0 &&
          _isReverseGeom(path.edge[stack.last], e)) {
        final pair = graph.edgeLen[path.edge[stack.last]] + graph.edgeLen[e];
        if (acc + pair <= spurMaxMetres) {
          acc += pair;
          stack.removeLast();
          stats.spursRemoved++;
          continue;
        }
      }
      acc = 0;
      stack.add(i);
    }
    if (stack.length == n - 1) return path;
    final out = PathBuilder();
    // The surviving segments are consecutive on the graph; rebuild from the
    // first survivor's start.
    if (stack.isEmpty) return path;
    final first = stack.first;
    out.start(path.lat[first - 1], path.lon[first - 1]);
    for (final i in stack) {
      out.add(path.lat[i], path.lon[i], path.way[i], path.dir[i], path.edge[i]);
    }
    return out;
  }

  // ------------------------------------------------------------ assembly

  void _addEdges(PathBuilder path, List<int> edges) {
    for (final e in edges) {
      final a = graph.edgeFrom[e], b = graph.edgeTo[e];
      if (path.isEmpty) {
        path.start(graph.nodeLat[a], graph.nodeLon[a]);
      } else if (path.lat.last != graph.nodeLat[a] || path.lon.last != graph.nodeLon[a]) {
        // Pieces that do not meet on the graph: a short dotted joint.
        path.add(graph.nodeLat[a], graph.nodeLon[a], -1, 0, edgeApprox);
      }
      path.add(graph.nodeLat[b], graph.nodeLon[b], graph.edgeWay[e],
          graph.isReversed(e) ? 1 : 0, e);
    }
  }

  void _approxSpan(PathBuilder path, List<double> lat, List<double> lon, int from,
      int to, List<double> arc, String cause) {
    for (var i = from; i <= to; i++) {
      path.add(lat[i], lon[i], -1, 0, edgeApprox);
    }
    stats.approxGaps++;
    stats.approxMetres += arc[to] - arc[from];
    stats.gaps.add('$_pattern ${lat[from].toStringAsFixed(5)} '
        '${lon[from].toStringAsFixed(5)} ${(arc[to] - arc[from]).round()} $cause');
  }

  /// Joins run [a] to run [b]: a shortest path hugging the shape, else the
  /// shape's own polyline, dotted.
  void _gap(PathBuilder path, _Run a, _Run b, ShapePolyline shape,
      List<double> lat, List<double> lon, List<double> arc) {
    if (a.edges.isEmpty || b.edges.isEmpty) return;
    final from = graph.edgeTo[a.edges.last], to = graph.edgeFrom[b.edges.first];
    if (from == to) return;
    final gap = arc[b.first] - arc[a.last];
    final cap = math.max(1.4 * gap + 120, 150.0);
    var cause = 'no route across gap';
    _search.run(from, cap * 4, target: to, corridor: shape);
    if (_search.distTo(to).isFinite) {
      final route = _search.pathTo(to);
      var len = 0.0;
      var offShape = 0.0;
      for (final e in route) {
        len += graph.edgeLen[e];
        final u = graph.edgeFrom[e], v = graph.edgeTo[e];
        offShape = math.max(
            offShape,
            shape.distanceTo((graph.nodeLat[u] + graph.nodeLat[v]) / 2,
                (graph.nodeLon[u] + graph.nodeLon[v]) / 2));
      }
      if (len <= cap && offShape <= bridgeCorridorMetres) {
        stats.bridged++;
        _addEdges(path, route);
        return;
      }
      cause = len > cap ? 'bridge too long' : 'bridge off shape';
    }
    stats.cause(cause);
    if (a.last + 1 <= b.first - 1) {
      _approxSpan(path, lat, lon, a.last + 1, b.first - 1, arc, cause);
    } else {
      final jump = haversineMetres(graph.nodeLat[from], graph.nodeLon[from],
          graph.nodeLat[to], graph.nodeLon[to]);
      stats.approxGaps++;
      stats.approxMetres += jump;
      stats.gaps.add('$_pattern ${graph.nodeLat[from].toStringAsFixed(5)} '
          '${graph.nodeLon[from].toStringAsFixed(5)} ${jump.round()} jump: $cause');
    }
  }

  // ------------------------------------------------------------ no shape

  /// Fallback for a pattern without a shape: each stop snaps to a road edge
  /// heading its way, consecutive stops are joined by the shortest path.
  PathBuilder _routeStopChain(Float64List stopLat, Float64List stopLon) {
    final n = stopLat.length;
    final edge = List<int>.filled(n, -1);
    for (var i = 0; i < n; i++) {
      final j = i + 1 < n ? i + 1 : i - 1;
      var bearing = bearingBetween(stopLat[i], stopLon[i], stopLat[j], stopLon[j]);
      if (i + 1 >= n) bearing = (bearing + 180) % 360;
      var best = double.infinity;
      for (final h in graph.near(stopLat[i], stopLon[i], stopChainSnapMetres)) {
        final delta = bearingDelta(graph.bearingOf(h.edge), bearing);
        if (delta > 90 || graph.isService(h.edge)) continue;
        final score = h.metres + 60 * delta / 180;
        if (score < best) {
          best = score;
          edge[i] = h.edge;
        }
      }
    }
    final path = PathBuilder();
    var prev = -1;
    for (var i = 0; i < n; i++) {
      if (edge[i] < 0) {
        stats.cause('stop off graph');
        path.add(stopLat[i], stopLon[i], -1, 0, edgeApprox);
        prev = -1;
        continue;
      }
      if (prev >= 0 && prev != edge[i]) {
        final from = graph.edgeTo[prev], to = graph.edgeFrom[edge[i]];
        final straight = haversineMetres(stopLat[i - 1], stopLon[i - 1], stopLat[i], stopLon[i]);
        final cap = math.max(2500.0, straight * 1.8);
        _search.run(from, cap, target: to);
        if (_search.distTo(to).isFinite) {
          _addEdges(path, _search.pathTo(to));
        } else {
          stats.cause('no route between stops');
          stats.approxGaps++;
        }
      }
      if (prev != edge[i]) _addEdges(path, [edge[i]]);
      prev = edge[i];
    }
    return path;
  }
}
