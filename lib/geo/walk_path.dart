/// §9.10 — the walked geometry of one leg, fetched on demand.
///
/// A small Overpass query over the leg's own bbox, a foot graph over the
/// answer and one shortest path. Everything here is best effort: no answer
/// means the leg stays a straight dotted line marked "≈", which is why the
/// call never throws and never blocks the planner.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'distance.dart';
import 'osm_fetch.dart';
import 'road_graph.dart';

/// Legs longer than this are not worth a network round trip: the walk cap is
/// 800 m and anything beyond is an origin/destination stretch, not a transfer.
const walkPathMaxMetres = 1500.0;

/// Bbox padding around the leg (§9.10).
const walkPathPadMetres = 150.0;

/// Answers stay for the session: a journey is re-selected all the time.
final _cache = <String, List<List<double>>?>{};

/// The walked path as `[lon, lat]` pairs, or null when it is unknown.
Future<List<List<double>>?> walkPath(
  double aLat,
  double aLon,
  double bLat,
  double bLon, {
  http.Client? client,
}) async {
  final key = '${aLat.toStringAsFixed(5)},${aLon.toStringAsFixed(5)},'
      '${bLat.toStringAsFixed(5)},${bLon.toStringAsFixed(5)}';
  if (_cache.containsKey(key)) return _cache[key];
  if (haversineMetres(aLat, aLon, bLat, bLon) > walkPathMaxMetres) return null;

  final c = client ?? http.Client();
  try {
    final padLat = walkPathPadMetres / 111320;
    final padLon = padLat / math.cos(aLat * math.pi / 180);
    final query = overpassQuery(
      math.min(aLat, bLat) - padLat,
      math.min(aLon, bLon) - padLon,
      math.max(aLat, bLat) + padLat,
      math.max(aLon, bLon) + padLon,
    );
    final r = await c
        .post(
          Uri.parse(osmEndpoints.first),
          headers: {
            'User-Agent': osmUserAgent,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: {'data': query},
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return _cache[key] = null;
    final ways = parseOsmJson(utf8.decode(r.bodyBytes, allowMalformed: true));
    if (ways.isEmpty) return _cache[key] = null;
    final graph = RoadGraph.build(ways, GraphMode.foot);
    return _cache[key] = _route(graph, aLat, aLon, bLat, bLon);
  } catch (_) {
    return _cache[key] = null;
  } finally {
    if (client == null) c.close();
  }
}

/// Shortest foot path between the graph nodes nearest each end. Snapping to a
/// node rather than splitting the edge is enough for a dotted line: the true
/// endpoints are added back at both ends.
List<List<double>>? _route(
  RoadGraph g,
  double aLat,
  double aLon,
  double bLat,
  double bLon,
) {
  final from = _nearestNode(g, aLat, aLon);
  final to = _nearestNode(g, bLat, bLon);
  if (from < 0 || to < 0) return null;
  if (from == to) return null;

  final dist = List<double>.filled(g.nodeCount, double.infinity);
  final prev = List<int>.filled(g.nodeCount, -1);
  dist[from] = 0;
  // ponytail: a list-backed queue, not a heap. A leg's bbox holds a few
  // thousand nodes; swap in a proper priority queue if a leg ever gets big.
  final queue = <int>[from];
  while (queue.isNotEmpty) {
    var best = 0;
    for (var i = 1; i < queue.length; i++) {
      if (dist[queue[i]] < dist[queue[best]]) best = i;
    }
    final node = queue.removeAt(best);
    if (node == to) break;
    for (final e in g.edgesFrom(node)) {
      final next = g.edgeTo[e];
      final d = dist[node] + g.edgeLen[e];
      if (d >= dist[next]) continue;
      dist[next] = d;
      prev[next] = node;
      queue.add(next);
    }
  }
  if (dist[to].isInfinite) return null;

  final points = <List<double>>[];
  for (var n = to; n != from && n >= 0; n = prev[n]) {
    points.add([g.nodeLon[n], g.nodeLat[n]]);
  }
  points.add([g.nodeLon[from], g.nodeLat[from]]);
  final path = points.reversed.toList();
  return [
    [aLon, aLat],
    ...path,
    [bLon, bLat],
  ];
}

int _nearestNode(RoadGraph g, double lat, double lon) {
  final hits = g.near(lat, lon, 80);
  if (hits.isEmpty) return -1;
  final hit = hits.first;
  final a = g.edgeFrom[hit.edge], b = g.edgeTo[hit.edge];
  return hit.fraction < 0.5 ? a : b;
}
