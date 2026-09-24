/// On-device pedestrian router: edge-projection snapping, A*, maneuvers.
///
/// Same code for every graph source. Never touches the network. The model
/// is docs/walk_routing.md; the numbers are `walk_costs.dart`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'walk_costs.dart';
import 'walk_graph.dart';

/// Farther than this from any walkable edge = outside coverage (no route).
const walkSnapMaxMetres = 150.0;

/// Edges this much farther than the nearest also count as where a point is.
const walkSnapSlackMetres = 7.0;
const walkSnapCandidates = 4;

const _cellLat = 54, _cellLon = 76; // ~60 m in 1e-5 degree units

/// A point projected onto an edge.
class WalkSnap {
  WalkSnap(this.edge, this.along, this.lat, this.lon, this.connector);
  final int edge;

  /// Metres from the edge's `a` end.
  final double along;
  final double lat, lon;

  /// Straight metres from the query point to the edge.
  final double connector;
}

enum ManeuverType {
  start,
  straight,
  slightLeft,
  left,
  sharpLeft,
  slightRight,
  right,
  sharpRight,
  cross,
  steps,
  arrive,
}

class Maneuver {
  const Maneuver(this.type, this.pointIndex, this.metres,
      {this.street, this.crossing});
  final ManeuverType type;

  /// Index into [WalkRoute.polyline] where it happens.
  final int pointIndex;

  /// Metres from here to the next maneuver (0 for arrive).
  final double metres;

  /// Street being followed, joined (turns), or crossed ([ManeuverType.cross]).
  final String? street;

  /// [WalkCrossing] type for [ManeuverType.cross].
  final int? crossing;

  @override
  String toString() => '${type.name}${street == null ? '' : ' $street'}'
      '${crossing == null ? '' : ' (crossing $crossing)'} @$pointIndex '
      '${metres.round()} m';
}

class WalkRoute {
  const WalkRoute(this.polyline, this.metres, this.maneuvers);

  /// `[lon, lat]` pairs on the real pedestrian edges, ends included.
  final List<List<double>> polyline;

  /// True length of [polyline].
  final double metres;
  final List<Maneuver> maneuvers;

  int get seconds => (metres / walkSpeedMetresPerSecond).round();
  double get endLat => polyline.last[1];
  double get endLon => polyline.last[0];
}

class _Piece {
  _Piece(this.pts, this.flags, this.name);
  final List<List<double>> pts; // [lon, lat]
  final int flags; // -1 connector
  final String? name;
}

class WalkRouter {
  WalkRouter(this.graph)
      : _cost = Float32List(graph.edgeCount),
        _g = Float64List(graph.nodeCount),
        _stamp = Int32List(graph.nodeCount),
        _prevEdge = Int32List(graph.nodeCount) {
    for (var e = 0; e < graph.edgeCount; e++) {
      _cost[e] = walkEdgeCost(graph.edgeFlags[e], graph.edgeLen[e]);
    }
    var biggest = 0;
    for (final c in graph.componentEdges) {
      biggest = math.max(biggest, c);
    }
    _minComponent = biggest * 0.02;
    _buildGrid();
  }

  final WalkGraph graph;
  final Float32List _cost;
  late final double _minComponent;

  late final int _rows, _cols, _minLat, _minLon;
  late final Int32List _cellStart, _cellEdge;

  final Float64List _g;
  final Int32List _stamp;
  final Int32List _prevEdge;
  int _run = 0;

  bool covers(double lat, double lon) => graph.header.covers(lat, lon);

  void _buildGrid() {
    var minLat = graph.header.minLat, minLon = graph.header.minLon;
    var maxLat = graph.header.maxLat, maxLon = graph.header.maxLon;
    for (var i = 0; i < graph.nodeCount; i++) {
      minLat = math.min(minLat, graph.nodeLat[i]);
      maxLat = math.max(maxLat, graph.nodeLat[i]);
      minLon = math.min(minLon, graph.nodeLon[i]);
      maxLon = math.max(maxLon, graph.nodeLon[i]);
    }
    _minLat = minLat;
    _minLon = minLon;
    _rows = (maxLat - minLat) ~/ _cellLat + 2;
    _cols = (maxLon - minLon) ~/ _cellLon + 2;
    final cells = <int>[], owners = <int>[];
    for (var e = 0; e < graph.edgeCount; e++) {
      final p = graph.points(e);
      final seen = <int>{};
      for (var i = 2; i < p.length; i += 2) {
        final steps = math.max(
            1, math.max((p[i] - p[i - 2]).abs() ~/ (_cellLat ~/ 2),
                (p[i + 1] - p[i - 1]).abs() ~/ (_cellLon ~/ 2)));
        for (var s = 0; s <= steps; s++) {
          final la = p[i - 2] + (p[i] - p[i - 2]) * s ~/ steps;
          final lo = p[i - 1] + (p[i + 1] - p[i - 1]) * s ~/ steps;
          final c = _cell(la, lo);
          if (seen.add(c)) {
            cells.add(c);
            owners.add(e);
          }
        }
      }
    }
    final start = Int32List(_rows * _cols + 1);
    for (final c in cells) {
      start[c + 1]++;
    }
    for (var i = 0; i < _rows * _cols; i++) {
      start[i + 1] += start[i];
    }
    final fill = Int32List.fromList(start);
    final edge = Int32List(cells.length);
    for (var i = 0; i < cells.length; i++) {
      edge[fill[cells[i]]++] = owners[i];
    }
    _cellStart = start;
    _cellEdge = edge;
  }

  int _cell(int lat, int lon) {
    final r = ((lat - _minLat) ~/ _cellLat).clamp(0, _rows - 1);
    final c = ((lon - _minLon) ~/ _cellLon).clamp(0, _cols - 1);
    return r * _cols + c;
  }

  /// Projects a point onto the nearest walkable edge, or null when nothing is
  /// within [walkSnapMaxMetres].
  WalkSnap? snap(double lat, double lon, {double maxMetres = walkSnapMaxMetres}) {
    final all = snapAll(lat, lon, maxMetres: maxMetres);
    return all.isEmpty ? null : all.first;
  }

  /// The nearest edge and every other edge nearly as near (within
  /// [walkSnapSlackMetres]), nearest first. A stop stands somewhere between
  /// the two generated sidewalks of a road: seeding both keeps a coordinate
  /// that GTFS placed on the wrong side of the carriageway from inventing a
  /// crossing.
  List<WalkSnap> snapAll(double lat, double lon,
      {double maxMetres = walkSnapMaxMetres}) {
    final qLat = lat * walkCoordScale, qLon = lon * walkCoordScale;
    final cosLat = math.cos(lat * math.pi / 180);
    final mLat = 1 / walkCoordScale * 111194.9266;
    final mLon = mLat * cosLat;
    final r0 = (qLat.floor() - _minLat) ~/ _cellLat;
    final c0 = (qLon.floor() - _minLon) ~/ _cellLon;
    final found = <WalkSnap>[];
    final maxRing = 1 + (maxMetres / 55).ceil();
    for (var radius = 1; radius <= maxRing; radius++) {
      // ring `radius` only (inner rings were searched already)
      for (var r = r0 - radius; r <= r0 + radius; r++) {
        if (r < 0 || r >= _rows) continue;
        for (var c = c0 - radius; c <= c0 + radius; c++) {
          if (c < 0 || c >= _cols) continue;
          if (radius > 1 &&
              r > r0 - radius &&
              r < r0 + radius &&
              c > c0 - radius &&
              c < c0 + radius) {
            continue;
          }
          final cell = r * _cols + c;
          for (var i = _cellStart[cell]; i < _cellStart[cell + 1]; i++) {
            final e = _cellEdge[i];
            if (graph.componentEdges[graph.component[graph.edgeA[e]]] <
                _minComponent) {
              continue;
            }
            found.add(_project(e, qLat, qLon, mLat, mLon));
          }
        }
      }
      // A ring covers at least `radius` cells (~60 m) around the point.
      if (found.isNotEmpty) {
        var nearest = double.infinity;
        for (final f in found) {
          nearest = math.min(nearest, f.connector);
        }
        if (nearest + walkSnapSlackMetres <= radius * 60.0) break;
      }
    }
    if (found.isEmpty) return const [];
    found.sort((a, b) => a.connector.compareTo(b.connector));
    if (found.first.connector > maxMetres) return const [];
    return [
      for (final f in found)
        if (f.connector <= found.first.connector + walkSnapSlackMetres) f
    ].take(walkSnapCandidates).toList();
  }

  WalkSnap _project(int e, double qLat, double qLon, double mLat, double mLon) {
    final p = graph.points(e);
    var bestD = double.infinity, bestAlong = 0.0;
    var bestLat = 0.0, bestLon = 0.0, cum = 0.0;
    for (var i = 2; i < p.length; i += 2) {
      final ax = (p[i - 1] - qLon) * mLon, ay = (p[i - 2] - qLat) * mLat;
      final bx = (p[i + 1] - qLon) * mLon, by = (p[i] - qLat) * mLat;
      final dx = bx - ax, dy = by - ay;
      final l2 = dx * dx + dy * dy;
      final t = l2 == 0 ? 0.0 : ((-ax * dx - ay * dy) / l2).clamp(0.0, 1.0);
      final px = ax + t * dx, py = ay + t * dy;
      final d = math.sqrt(px * px + py * py);
      final segLen = segMetres(p[i - 2], p[i - 1], p[i], p[i + 1]);
      if (d < bestD) {
        bestD = d;
        bestAlong = cum + t * segLen;
        bestLat = (p[i - 2] + (p[i] - p[i - 2]) * t) / walkCoordScale;
        bestLon = (p[i - 1] + (p[i + 1] - p[i - 1]) * t) / walkCoordScale;
      }
      cum += segLen;
    }
    return WalkSnap(e, bestAlong.clamp(0.0, graph.edgeLen[e]), bestLat,
        bestLon, bestD);
  }

  /// Best walking route between two coordinates, or null when either end is
  /// outside the graph or no path exists.
  WalkRoute? route(double fromLat, double fromLon, double toLat, double toLon) {
    final starts = snapAll(fromLat, fromLon), goals = snapAll(toLat, toLon);
    if (starts.isEmpty || goals.isEmpty) return null;

    // Walking along one edge is a candidate for every same-edge pair; a detour
    // may still win when both points sit at its ends (a node touches many).
    var bound = double.infinity;
    (int, int)? directPair;
    for (var si = 0; si < starts.length; si++) {
      for (var ti = 0; ti < goals.length; ti++) {
        final a = starts[si], b = goals[ti];
        if (a.edge != b.edge) continue;
        final len = graph.edgeLen[a.edge];
        final c = a.connector +
            b.connector +
            (len == 0 ? 0 : _cost[a.edge] * (a.along - b.along).abs() / len);
        if (c < bound) {
          bound = c;
          directPair = (si, ti);
        }
      }
    }
    final found = _search(starts, goals, bound);
    final List<_Piece> body;
    final WalkSnap a, b;
    if (found != null) {
      body = found.pieces;
      a = starts[found.start];
      b = goals[found.goal];
    } else if (directPair != null) {
      a = starts[directPair.$1];
      b = goals[directPair.$2];
      body = [_slice(a.edge, a.along, b.along)];
    } else {
      return null;
    }
    final pieces = <_Piece>[
      if (a.connector > 0.5)
        _Piece([
          [fromLon, fromLat],
          [a.lon, a.lat],
        ], -1, null),
      ...body,
      if (b.connector > 0.5)
        _Piece([
          [b.lon, b.lat],
          [toLon, toLat],
        ], -1, null),
    ];
    return _assemble(pieces);
  }

  /// A route from an arbitrary current position to where [current] was
  /// heading: the off-route / "Ricalcola" primitive.
  WalkRoute? reroute(double lat, double lon, WalkRoute current) =>
      route(lat, lon, current.endLat, current.endLon);

  // -- search ---------------------------------------------------------------

  /// Cheapest path from any of [ss] to any of [ts] costing less than [bound]
  /// (connectors count), or null. Every start end is seeded with its
  /// connector plus the walk along its edge; every goal end has a tail.
  ({List<_Piece> pieces, int start, int goal})? _search(
      List<WalkSnap> ss, List<WalkSnap> ts, double bound) {
    final g = graph;
    final tLat = ts.first.lat, tLon = ts.first.lon;
    final cosLat = math.cos(tLat * math.pi / 180);
    final mLat = 111194.9266, mLon = mLat * cosLat;
    // Other goal candidates lie a few metres off the first: shave the bound.
    const hSlack = walkSnapSlackMetres * 3;
    double h(int n) {
      final dy = (g.lat(n) - tLat) * mLat, dx = (g.lon(n) - tLon) * mLon;
      return math.max(0, minWalkFactor * math.sqrt(dx * dx + dy * dy) - hSlack);
    }

    _run++;
    final heap = _Heap();
    final seedOwner = <int, int>{}; // node -> start candidate (only for seeds)
    void seed(int n, double cost, int owner) {
      if (_stamp[n] == _run && _g[n] <= cost) return;
      _stamp[n] = _run;
      _g[n] = cost;
      _prevEdge[n] = -1;
      seedOwner[n] = owner;
      heap.push(cost + h(n), n);
    }

    for (var i = 0; i < ss.length; i++) {
      final s = ss[i];
      final sl = g.edgeLen[s.edge];
      seed(g.edgeA[s.edge],
          s.connector + _cost[s.edge] * (sl == 0 ? 0 : s.along / sl), i);
      seed(g.edgeB[s.edge],
          s.connector + _cost[s.edge] * (sl == 0 ? 0 : (sl - s.along) / sl), i);
    }

    // goal node -> (tail cost, goal candidate, arrives at the edge's a end)
    final tails = <int, (double, int, bool)>{};
    for (var i = 0; i < ts.length; i++) {
      final t = ts[i];
      final tl = g.edgeLen[t.edge];
      final tailA = t.connector + _cost[t.edge] * (tl == 0 ? 0 : t.along / tl);
      final tailB = t.connector + _cost[t.edge] * (tl == 0 ? 0 : (tl - t.along) / tl);
      final a = g.edgeA[t.edge], b = g.edgeB[t.edge];
      if (!tails.containsKey(a) || tails[a]!.$1 > tailA) tails[a] = (tailA, i, true);
      if (!tails.containsKey(b) || tails[b]!.$1 > tailB) tails[b] = (tailB, i, false);
    }

    var best = bound;
    var bestNode = -1;
    while (heap.isNotEmpty) {
      final f = heap.topKey;
      if (f >= best) break;
      final n = heap.pop();
      final gn = _g[n];
      if (f > gn + h(n) + 1e-6) continue; // stale
      final tail = tails[n];
      if (tail != null && gn + tail.$1 < best) {
        best = gn + tail.$1;
        bestNode = n;
      }
      for (var i = g.adjStart[n]; i < g.adjStart[n + 1]; i++) {
        final e = g.adjEdge[i];
        final o = g.other(e, n);
        final c = gn + _cost[e];
        if (_stamp[o] == _run && _g[o] <= c) continue;
        _stamp[o] = _run;
        _g[o] = c;
        _prevEdge[o] = e;
        seedOwner.remove(o); // reached by walking: no longer a bare seed
        heap.push(c + h(o), o);
      }
    }
    if (bestNode < 0) return null;

    final chain = <(int, bool)>[]; // edge, traversed a->b
    var n = bestNode;
    while (_prevEdge[n] >= 0) {
      final e = _prevEdge[n];
      final from = g.other(e, n);
      chain.add((e, g.edgeA[e] == from));
      n = from;
    }
    final si = seedOwner[n] ?? 0;
    final s = ss[si];
    final tail = tails[bestNode]!;
    final t = ts[tail.$2];
    final out = <_Piece>[];
    final startTo = n == g.edgeA[s.edge] ? 0.0 : g.edgeLen[s.edge];
    if ((s.along - startTo).abs() > 0.05) out.add(_slice(s.edge, s.along, startTo));
    for (final (e, fwd) in chain.reversed) {
      out.add(_slice(e, fwd ? 0 : g.edgeLen[e], fwd ? g.edgeLen[e] : 0));
    }
    final endFrom = tail.$3 ? 0.0 : g.edgeLen[t.edge];
    if ((t.along - endFrom).abs() > 0.05) out.add(_slice(t.edge, endFrom, t.along));
    return (pieces: out, start: si, goal: tail.$2);
  }

  /// The piece of edge [e] between two along-distances (either order).
  _Piece _slice(int e, double from, double to) {
    final p = graph.points(e);
    final pts = <List<double>>[];
    final lens = <double>[0];
    for (var i = 2; i < p.length; i += 2) {
      lens.add(lens.last + segMetres(p[i - 2], p[i - 1], p[i], p[i + 1]));
    }
    List<double> at(double d) {
      d = d.clamp(0.0, lens.last);
      for (var i = 1; i < lens.length; i++) {
        if (d <= lens[i]) {
          final seg = lens[i] - lens[i - 1];
          final t = seg == 0 ? 0.0 : (d - lens[i - 1]) / seg;
          final la = p[(i - 1) * 2] + (p[i * 2] - p[(i - 1) * 2]) * t;
          final lo = p[(i - 1) * 2 + 1] + (p[i * 2 + 1] - p[(i - 1) * 2 + 1]) * t;
          return [lo / walkCoordScale, la / walkCoordScale];
        }
      }
      return [p[p.length - 1] / walkCoordScale, p[p.length - 2] / walkCoordScale];
    }

    final lo = math.min(from, to), hi = math.max(from, to);
    pts.add(at(lo));
    for (var i = 1; i < lens.length - 1; i++) {
      if (lens[i] > lo && lens[i] < hi) {
        pts.add([p[i * 2 + 1] / walkCoordScale, p[i * 2] / walkCoordScale]);
      }
    }
    pts.add(at(hi));
    final name = graph.edgeName[e];
    return _Piece(from <= to ? pts : pts.reversed.toList(), graph.edgeFlags[e],
        name < 0 ? null : graph.names[name]);
  }

  // -- output ---------------------------------------------------------------

  WalkRoute _assemble(List<_Piece> pieces) {
    final poly = <List<double>>[];
    final startIdx = <int>[];
    for (final piece in pieces) {
      startIdx.add(poly.isEmpty ? 0 : poly.length - 1);
      for (final p in piece.pts) {
        if (poly.isNotEmpty && _m(poly.last, p) < 0.05) continue;
        poly.add(p);
      }
    }
    if (poly.length == 1) poly.add(poly.first);
    final cum = <double>[0];
    for (var i = 1; i < poly.length; i++) {
      cum.add(cum.last + _m(poly[i - 1], poly[i]));
    }
    final total = cum.last;

    final events = <(int, ManeuverType, String?, int?)>[];
    String? firstName;
    for (final p in pieces) {
      if (p.flags >= 0 && p.name != null) {
        firstName = p.name;
        break;
      }
    }
    events.add((0, ManeuverType.start, firstName, null));

    // The piece each vertex belongs to (a joint belongs to the piece starting there).
    final pieceAt = List<int>.filled(poly.length, 0);
    for (var i = 0; i < pieces.length; i++) {
      final to = i + 1 < pieces.length ? startIdx[i + 1] : poly.length - 1;
      for (var v = startIdx[i]; v <= to && v < poly.length; v++) {
        pieceAt[v] = i;
      }
    }

    // Crossings and steps: one event per run.
    int? prevKind;
    for (final piece in pieces) {
      if (piece.flags < 0) continue;
      final kind = WalkFlags.kind(piece.flags);
      final at = startIdx[pieces.indexOf(piece)].clamp(0, poly.length - 1);
      if (kind == WalkKind.crossing && prevKind != WalkKind.crossing) {
        events.add((at, ManeuverType.cross, piece.name, WalkFlags.sub(piece.flags)));
      } else if (kind == WalkKind.steps && prevKind != WalkKind.steps) {
        events.add((at, ManeuverType.steps, piece.name, null));
      }
      prevKind = kind;
    }

    // Turns: the heading over the next 15 m against the last announced
    // heading, so a curve, or a jitter of short edges around a corner, gives
    // one maneuver, not a dozen.
    var anchor = _bearingAhead(poly, cum, 0);
    var lastAt = 0;
    for (var v = 1; v < poly.length - 1; v++) {
      if (cum[v] - cum[lastAt] < 4) continue;
      final ahead = _bearingAhead(poly, cum, v);
      final d = _angleDiff(ahead, anchor);
      if (d.abs() < walkTurnDegrees) continue;
      anchor = ahead;
      final piece = pieces[pieceAt[v]];
      final kind = piece.flags < 0 ? -1 : WalkFlags.kind(piece.flags);
      if (kind == WalkKind.crossing || kind == WalkKind.steps || kind < 0) continue;
      events.add((v, _classify(d), piece.name, null));
      lastAt = v;
    }

    // Same heading, new street name: "continue on X".
    String? current = firstName;
    for (var i = 0; i < pieces.length; i++) {
      final piece = pieces[i];
      if (piece.flags < 0) continue;
      final kind = WalkFlags.kind(piece.flags);
      if (kind == WalkKind.crossing || kind == WalkKind.steps || piece.name == null) continue;
      if (current != null && piece.name != current) {
        final at = startIdx[i].clamp(0, poly.length - 1);
        if (!events.any((e) => (cum[e.$1] - cum[at]).abs() < 10)) {
          events.add((at, ManeuverType.straight, piece.name, null));
        }
      }
      current = piece.name;
    }
    events.add((poly.length - 1, ManeuverType.arrive, null, null));

    // In order; two events at (nearly) the same place keep the informative one.
    events.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.index.compareTo(b.$2.index));
    final kept = <(int, ManeuverType, String?, int?)>[];
    for (final ev in events) {
      if (kept.isNotEmpty &&
          ev.$2 != ManeuverType.arrive &&
          kept.last.$2 != ManeuverType.start &&
          cum[ev.$1] - cum[kept.last.$1] < 3) {
        final prev = kept.last;
        final prevSpecial = prev.$2 == ManeuverType.cross || prev.$2 == ManeuverType.steps;
        if (!prevSpecial) kept[kept.length - 1] = ev;
        continue;
      }
      kept.add(ev);
    }
    final maneuvers = <Maneuver>[];
    for (var i = 0; i < kept.length; i++) {
      final ev = kept[i];
      final next = i + 1 < kept.length ? cum[kept[i + 1].$1] : total;
      maneuvers.add(Maneuver(ev.$2, ev.$1, i + 1 < kept.length ? next - cum[ev.$1] : 0,
          street: ev.$3, crossing: ev.$4));
    }
    return WalkRoute(poly, total, maneuvers);
  }
}

/// Heading change that makes a maneuver.
const walkTurnDegrees = 30.0;

/// Bearing from vertex [v] to the first vertex 15 m on (or the last one).
double _bearingAhead(List<List<double>> poly, List<double> cum, int v) {
  var b = v + 1;
  while (b < poly.length - 1 && cum[b] - cum[v] < 15) {
    b++;
  }
  return _bearing(poly[v], poly[math.min(b, poly.length - 1)]);
}

/// Signed difference `a - b` in degrees, in (-180, 180]: positive = right.
double _angleDiff(double a, double b) {
  var d = a - b;
  while (d > 180) {
    d -= 360;
  }
  while (d <= -180) {
    d += 360;
  }
  return d;
}

ManeuverType _classify(double d) {
  final m = d.abs();
  final right = d > 0;
  if (m < 60) return right ? ManeuverType.slightRight : ManeuverType.slightLeft;
  if (m < 130) return right ? ManeuverType.right : ManeuverType.left;
  return right ? ManeuverType.sharpRight : ManeuverType.sharpLeft;
}

double _bearing(List<double> a, List<double> b) {
  final dy = b[1] - a[1];
  final dx = (b[0] - a[0]) * math.cos(a[1] * math.pi / 180);
  return math.atan2(dx, dy) * 180 / math.pi;
}

double _m(List<double> a, List<double> b) {
  final dy = (b[1] - a[1]) * 111194.9266;
  final dx = (b[0] - a[0]) * 111194.9266 * math.cos((a[1] + b[1]) / 2 * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

/// Minimal binary min-heap of (key, node).
class _Heap {
  Float64List _k = Float64List(256);
  Int32List _v = Int32List(256);
  int _n = 0;
  bool get isNotEmpty => _n > 0;
  double get topKey => _k[0];

  void push(double key, int v) {
    if (_n == _k.length) {
      _k = Float64List(_n * 2)..setRange(0, _n, _k);
      _v = Int32List(_n * 2)..setRange(0, _n, _v);
    }
    var i = _n++;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_k[p] <= key) break;
      _k[i] = _k[p];
      _v[i] = _v[p];
      i = p;
    }
    _k[i] = key;
    _v[i] = v;
  }

  int pop() {
    final top = _v[0];
    final key = _k[--_n], v = _v[_n];
    var i = 0;
    while (true) {
      var c = 2 * i + 1;
      if (c >= _n) break;
      if (c + 1 < _n && _k[c + 1] < _k[c]) c++;
      if (_k[c] >= key) break;
      _k[i] = _k[c];
      _v[i] = _v[c];
      i = c;
    }
    _k[i] = key;
    _v[i] = v;
    return top;
  }
}
