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

/// Merges every snapped pattern and returns the ambient FeatureCollection.
String ambientGeoJson(TransitIndex ix, LineNetwork net) {
  final tiers = routeTiers(ix);
  final merger = LineMerger();
  final routeTier = <String, int>{};
  for (final p in net.patterns) {
    final type = ix.routeTypeOfPattern(p.pattern);
    final name = ix.routeShortNameOfPattern(p.pattern);
    routeTier[name] = tiers[ix.patternRoute[p.pattern]];
    for (var i = 1; i < p.vertexCount; i++) {
      merger.add(
        mode: type,
        route: name,
        way: p.vertexWay[i],
        aLat: p.vertexLat[i - 1] / 1e6,
        aLon: p.vertexLon[i - 1] / 1e6,
        bLat: p.vertexLat[i] / 1e6,
        bLon: p.vertexLon[i] / 1e6,
      );
    }
  }

  offsetSharedBusTram(merger.segments);

  final features = <Map<String, dynamic>>[];
  var id = 0;

  // Metro and funicular are not snapped to OSM, so way identity cannot merge
  // them: draw the longest direction-0 pattern of each such route as is, once,
  // so the two directions do not double the line (§9.3).
  final rail = <int, SnappedPattern>{};
  for (final p in net.patterns) {
    final type = ix.routeTypeOfPattern(p.pattern);
    if (type != RouteType.metro && type != RouteType.funicular) continue;
    if (ix.patternDir[p.pattern] != 0) continue;
    final route = ix.patternRoute[p.pattern];
    if ((rail[route]?.vertexCount ?? 0) < p.vertexCount) rail[route] = p;
  }
  for (final e in rail.entries) {
    final p = e.value;
    features.add({
      'type': 'Feature',
      'id': id++,
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          for (var i = 0; i < p.vertexCount; i++)
            [p.vertexLon[i] / 1e6, p.vertexLat[i] / 1e6],
        ],
      },
      'properties': {
        'mode': _modeKey(ix.routeTypes[e.key]),
        'routes': ix.routeShortNames[e.key],
        'n': 1,
        'tier': 0,
        'arrow': 0,
        'shade': shadeOf(ix.routeShortNames[e.key]),
      },
    });
  }
  for (final chain in chainSegments(merger.segments)) {
    final coords = [
      for (var i = 0; i + 1 < chain.pts.length; i += 2)
        [
          double.parse(chain.pts[i + 1].toStringAsFixed(6)),
          double.parse(chain.pts[i].toStringAsFixed(6)),
        ],
    ];
    if (coords.length < 2) continue;
    features.add({
      'type': 'Feature',
      'id': id++,
      'geometry': {'type': 'LineString', 'coordinates': coords},
      'properties': {
        'mode': _modeKey(chain.mode),
        'routes': chain.routes.join(','),
        'n': chain.routes.length,
        'tier': chain.routes
            .map((r) => routeTier[r] ?? 2)
            .reduce((a, b) => a < b ? a : b),
        'arrow': chain.oneDirection ? 1 : 0,
        'shade': chain.routes.length == 1 ? shadeOf(chain.routes.first) : -1,
      },
    });
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

/// §9.5 — where a tram segment and a bus segment run within
/// [sharedMetres] and [sharedDegrees] of parallel, push the two apart so both
/// stay visible on the shared street. Bus to one side, tram to the other.
///
/// ponytail: the shift is baked into the geometry in metres, not applied as a
/// pixel `line-offset` at draw time, so it shrinks with the zoom instead of
/// holding half a stroke width. Move it into the layer if it reads too thin.
const sharedMetres = 12.0, sharedDegrees = 15.0, sharedShiftMetres = 3.0;

void offsetSharedBusTram(List<MergedSeg> segs) {
  final trams = [for (final s in segs) if (s.mode == RouteType.tram) s];
  if (trams.isEmpty) return;
  final cell = sharedMetres / 111320 * 2;
  final grid = <int, List<MergedSeg>>{};
  int key(double lat, double lon) =>
      ((lat / cell).floor() << 20) ^ (lon / cell).floor();
  for (final t in trams) {
    grid.putIfAbsent(key(t.aLat, t.aLon), () => []).add(t);
    grid.putIfAbsent(key(t.bLat, t.bLon), () => []).add(t);
  }

  final shift = <MergedSeg, int>{};
  for (final s in segs) {
    if (s.mode == RouteType.tram) continue;
    for (final d in const [-1, 0, 1]) {
      for (final e in const [-1, 0, 1]) {
        final near = grid[key(s.aLat + d * cell, s.aLon + e * cell)];
        if (near == null) continue;
        for (final t in near) {
          if (!_parallelAndClose(s, t)) continue;
          shift[s] = 1;
          shift[t] = -1;
        }
      }
    }
  }
  for (final e in shift.entries) {
    _shift(e.key, e.value * sharedShiftMetres);
  }
}

bool _parallelAndClose(MergedSeg a, MergedSeg b) {
  final da = (_bearing(a) - _bearing(b)).abs() % 180;
  if (math.min(da, 180 - da) > sharedDegrees) return false;
  return _metres(a.aLat, a.aLon, b.aLat, b.aLon) <= sharedMetres ||
      _metres(a.bLat, a.bLon, b.bLat, b.bLon) <= sharedMetres;
}

/// Undirected bearing in [0, 180): both segments must measure the same way or
/// the two shifts would land on the same side.
double _bearing(MergedSeg s) {
  final dy = (s.bLat - s.aLat) * 111320;
  final dx = (s.bLon - s.aLon) * 111320 * 0.707;
  final deg = math.atan2(dy, dx) * 180 / math.pi;
  return (deg + 360) % 180;
}

void _shift(MergedSeg s, double metres) {
  final rad = _bearing(s) * math.pi / 180;
  final dLat = math.cos(rad) * metres / 111320;
  final dLon = -math.sin(rad) * metres / (111320 * 0.707);
  s.aLat += dLat;
  s.aLon += dLon;
  s.bLat += dLat;
  s.bLon += dLon;
}
