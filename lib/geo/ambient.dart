/// The merged ambient network as GeoJSON (§9.4).
///
/// Built once on the desktop by `tool/build_lines.dart` and shipped gzipped in
/// `assets/ambient.json.gz`: merging the whole network costs hundreds of MB of
/// transient objects, which is a desktop problem, not a phone one. The phone
/// only gunzips and hands the string to MapLibre.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../data/transit_index.dart';
import 'line_merge.dart';
import 'lines_io.dart';
import 'pattern_snap.dart';
import 'road_graph.dart';

/// Peak window used for the headway tier: two hours of a weekday morning.
const peakStart = 7 * 3600, peakEnd = 9 * 3600;

/// A bus route counts as frequent at 12 departures in the peak window
/// (headway <= 10 min) on its busiest service.
const peakTripsForTier1 = 12;

/// Tier per route: 0 = tram/metro/funicular, 1 = frequent bus, 2 = other bus.
List<int> routeTiers(TransitIndex ix) {
  final peak = <int, Map<int, int>>{}; // route -> service -> departures
  for (var t = 0; t < ix.tripCount; t++) {
    final dep = ix.depOf(t, 0);
    if (dep < peakStart || dep >= peakEnd) continue;
    final route = ix.patternRoute[ix.tripPattern[t]];
    final byService = peak.putIfAbsent(route, () => {});
    byService.update(ix.tripService[t], (v) => v + 1, ifAbsent: () => 1);
  }
  return [
    for (var r = 0; r < ix.routeCount; r++)
      if (ix.routeTypes[r] != RouteType.bus)
        0
      else if ((peak[r]?.values.fold(0, (a, b) => a > b ? a : b) ?? 0) >=
          peakTripsForTier1)
        1
      else
        2,
  ];
}

/// Shades per mode family, used when a feature carries a single route. GTT
/// publishes no usable `route_color`, so the shade is deterministic from the
/// route name and resolved to a colour by the map layer (§9.4).
const shadeCount = 6;

int shadeOf(String routeShortName) {
  var h = 0;
  for (final c in routeShortName.codeUnits) {
    h = (h * 31 + c) & 0x7FFFFFFF;
  }
  return h % shadeCount;
}

String _modeKey(int routeType) => switch (routeType) {
      RouteType.tram => 'tram',
      RouteType.metro => 'metro',
      RouteType.funicular => 'funicular',
      _ => 'bus',
    };

/// Draw order in the source: later features paint on top. Where a bus and a
/// tram share a street the tram (wider, see `ambientWidth`) is drawn first, so
/// the bus stroke sits inside it and both stay visible with no geometry shift.
int _drawRank(int type) => switch (type) {
      RouteType.tram => 0,
      RouteType.bus => 1,
      _ => 2,
    };

double _r6(double v) => double.parse(v.toStringAsFixed(6));

/// Merges every matched pattern by graph segment identity and returns the
/// ambient FeatureCollection: road-matched chains, dotted approximate
/// stretches (`approx = 1`, the GTFS shape itself), and one line per metro or
/// funicular route.
String ambientGeoJson(
    TransitIndex ix, LineNetwork net, Map<GraphMode, RoadGraph> graphs) {
  final tiers = routeTiers(ix);
  final merger = LineMerger();
  final routeTier = <String, int>{};
  // Dotted stretches keyed by their exact points: patterns sharing a stretch
  // share the feature.
  final approx = <String, ({int mode, List<double> pts, Set<String> routes})>{};

  final rail = <int, List<SnappedPattern>>{};
  for (final p in net.patterns) {
    final type = ix.routeTypeOfPattern(p.pattern);
    final route = ix.routeShortNameOfPattern(p.pattern);
    routeTier[route] = tiers[ix.patternRoute[p.pattern]];
    final edges = p.vertexEdge;
    if (edges == null) continue;
    final graph = graphs[switch (type) {
      RouteType.tram => GraphMode.tram,
      RouteType.bus => GraphMode.bus,
      _ => GraphMode.rail,
    }];

    if (edges.contains(edgeShape)) {
      (rail[ix.patternRoute[p.pattern]] ??= []).add(p);
      continue;
    }
    var lastEdge = -3;
    final run = <double>[]; // flat lat,lon of the current dotted stretch
    void flush() {
      if (run.length >= 4) {
        final key = '$type/${run.join(',')}';
        approx
            .putIfAbsent(key, () => (mode: type, pts: [...run], routes: <String>{}))
            .routes
            .add(route);
      }
      run.clear();
    }

    for (var k = 1; k < p.vertexCount; k++) {
      final e = edges[k];
      final lat = p.vertexLat[k] / 1e6, lon = p.vertexLon[k] / 1e6;
      if (e >= 0 && graph != null) {
        flush();
        if (e == lastEdge) continue; // a stop's own vertex inside the segment
        lastEdge = e;
        final a = graph.edgeFrom[e], b = graph.edgeTo[e];
        merger.add(
          mode: type,
          route: route,
          from: a,
          to: b,
          fromLat: graph.nodeLat[a],
          fromLon: graph.nodeLon[a],
          toLat: graph.nodeLat[b],
          toLon: graph.nodeLon[b],
        );
      } else {
        lastEdge = -3;
        if (run.isEmpty) run..add(p.vertexLat[k - 1] / 1e6)..add(p.vertexLon[k - 1] / 1e6);
        run..add(lat)..add(lon);
      }
    }
    flush();
  }

  final features = <Map<String, dynamic>>[];
  var id = 0;
  void feature(int mode, List<String> routes, List<double> pts,
      {required bool oneWay, required bool dotted}) {
    final coords = <List<double>>[];
    for (var i = 0; i + 1 < pts.length; i += 2) {
      final c = [_r6(pts[i + 1]), _r6(pts[i])];
      if (coords.isNotEmpty && coords.last[0] == c[0] && coords.last[1] == c[1]) continue;
      coords.add(c);
    }
    if (coords.length < 2) return;
    features.add({
      'type': 'Feature',
      'id': id++,
      'geometry': {'type': 'LineString', 'coordinates': coords},
      'properties': {
        'mode': _modeKey(mode),
        'routes': routes.join(','),
        'n': routes.length,
        'tier': routes.map((r) => routeTier[r] ?? 2).reduce(math.min),
        'arrow': oneWay ? 1 : 0,
        if (dotted) 'approx': 1,
        'shade': routes.length == 1 ? shadeOf(routes.first) : -1,
      },
    });
  }

  final chains = chainSegments(merger.segments)
    ..sort((a, b) => _drawRank(a.mode).compareTo(_drawRank(b.mode)));
  for (final c in chains) {
    feature(c.mode, c.routes, c.pts, oneWay: c.oneDirection, dotted: false);
  }
  for (final a in approx.values) {
    feature(a.mode, a.routes.toList()..sort(), a.pts, oneWay: false, dotted: true);
  }

  // Metro and funicular with a published shape: each
  // route draws its longest pattern, plus any pattern serving a stop the ones
  // drawn so far do not (a branch), so the two directions never double up.
  for (final e in rail.entries) {
    final patterns = e.value..sort((a, b) => b.vertexCount.compareTo(a.vertexCount));
    final covered = <int>{};
    for (final p in patterns) {
      final stops = {
        for (var i = 0; i < p.stopVertex.length; i++) ix.patternStopAt(p.pattern, i)
      };
      if (covered.isNotEmpty && covered.containsAll(stops)) continue;
      covered.addAll(stops);
      feature(
        ix.routeTypes[e.key],
        [ix.routeShortNames[e.key]],
        [
          for (var i = 0; i < p.vertexCount; i++) ...[
            p.vertexLat[i] / 1e6,
            p.vertexLon[i] / 1e6,
          ]
        ],
        oneWay: false,
        dotted: p.vertexEdge != null && p.vertexEdge!.contains(edgeApprox),
      );
    }
  }
  return jsonEncode({'type': 'FeatureCollection', 'features': features});
}

/// Minimum connector length: below this the dot already covers the road.
const connectorMinMetres = 3.0;

/// Dashed connectors from a stop's true coordinate to where its pattern snaps
/// on the road (§9.7). Deduped when two patterns snap within a metre.
String connectorsGeoJson(TransitIndex ix, LineNetwork net) {
  final seen = <int>{};
  final features = <Map<String, dynamic>>[];
  var id = 0;
  for (final p in net.patterns) {
    final mode = _modeKey(ix.routeTypeOfPattern(p.pattern));
    for (var i = 0; i < p.stopVertex.length; i++) {
      final stop = ix.patternStopAt(p.pattern, i);
      final lat = ix.stopLat[stop], lon = ix.stopLon[stop];
      final sLat = p.stopLat[i] / 1e6, sLon = p.stopLon[i] / 1e6;
      final metres = _metres(lat, lon, sLat, sLon);
      if (metres < connectorMinMetres) continue;
      // One connector per (stop, snapped point rounded to ~1 m).
      if (!seen.add(Object.hash(stop, (sLat * 1e5).round(), (sLon * 1e5).round()))) {
        continue;
      }
      features.add({
        'type': 'Feature',
        'id': id++,
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [double.parse(lon.toStringAsFixed(6)), double.parse(lat.toStringAsFixed(6))],
            [double.parse(sLon.toStringAsFixed(6)), double.parse(sLat.toStringAsFixed(6))],
          ],
        },
        'properties': {'stop': stop, 'mode': mode},
      });
    }
  }
  return jsonEncode({'type': 'FeatureCollection', 'features': features});
}

double _metres(double aLat, double aLon, double bLat, double bLon) {
  final dy = (aLat - bLat) * 111320;
  final dx = (aLon - bLon) * 111320 * 0.707; // cos(45°), Turin
  return math.sqrt(dy * dy + dx * dx);
}

