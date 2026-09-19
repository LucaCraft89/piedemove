/// 9.2 — the directed bus/road and tram graphs built from raw Overpass ways.
///
/// Node identity is the **exact stored coordinate**: Overpass repeats the
/// literal shared coordinate at a real junction, so no tolerance merge is ever
/// needed (and a tolerance merge would glue unrelated ways together).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'distance.dart';

enum GraphMode { bus, tram }

class OsmWay {
  OsmWay(this.id, this.tags, this.lat, this.lon);
  final int id;
  final Map<String, String> tags;
  final Float64List lat;
  final Float64List lon;
}

/// Parses one Overpass `out geom` response. Ways without geometry are skipped.
List<OsmWay> parseOsmJson(String body) {
  final root = jsonDecode(body);
  final elements = (root is Map && root['elements'] is List)
      ? root['elements'] as List
      : const [];
  final out = <OsmWay>[];
  for (final e in elements) {
    if (e is! Map || e['type'] != 'way') continue;
    final geom = e['geometry'];
    if (geom is! List || geom.length < 2) continue;
    final lat = Float64List(geom.length);
    final lon = Float64List(geom.length);
    for (var i = 0; i < geom.length; i++) {
      final p = geom[i];
      lat[i] = (p['lat'] as num).toDouble();
      lon[i] = (p['lon'] as num).toDouble();
    }
    final tags = <String, String>{};
    final t = e['tags'];
    if (t is Map) {
      t.forEach((k, v) => tags['$k'] = '$v');
    }
    out.add(OsmWay((e['id'] as num).toInt(), tags, lat, lon));
  }
  return out;
}

const _drivableHighways = {
  'motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified',
  'residential', 'living_street', 'busway', 'service',
  'motorway_link', 'trunk_link', 'primary_link', 'secondary_link',
  'tertiary_link',
};

const _yes = {'yes', 'true', '1', 'designated', 'official', 'permissive'};

bool _busAllowed(Map<String, String> tags) {
  final bus = tags['bus'] ?? tags['psv'];
  if (bus != null && _yes.contains(bus)) return true;
  final access = tags['access'];
  final motor = tags['motor_vehicle'];
  const blocked = {'no', 'private', 'customers', 'delivery'};
  if (motor != null && blocked.contains(motor)) return false;
  if (access != null && blocked.contains(access)) return false;
  return true;
}

/// Whether a way belongs to [mode]'s graph at all.
bool wayInMode(OsmWay w, GraphMode mode) {
  if (mode == GraphMode.tram) return w.tags['railway'] == 'tram';
  if (w.tags['railway'] == 'tram' && w.tags['highway'] == null) return false;
  final hw = w.tags['highway'];
  if (hw == null || !_drivableHighways.contains(hw)) return false;
  // Parking aisles and driveways are never a bus route and sit right next to
  // stops, where they would steal the snap from the street.
  const notARoute = {'parking_aisle', 'driveway', 'drive-through', 'emergency_access'};
  if (hw == 'service' && notARoute.contains(w.tags['service'] ?? '')) return false;
  return _busAllowed(w.tags);
}

/// (forward, backward) travel allowed along the way's own point order.
(bool, bool) wayDirections(OsmWay w, GraphMode mode) {
  final oneway = w.tags['oneway'];
  final junction = w.tags['junction'];
  var forward = true;
  var backward = true;
  if (oneway == '-1' || oneway == 'reverse') {
    forward = false;
  } else if (_yes.contains(oneway ?? '') ||
      junction == 'roundabout' ||
      junction == 'circular' ||
      w.tags['highway'] == 'motorway') {
    backward = false;
  }
  if (mode == GraphMode.bus && !backward) {
    final busway = w.tags['busway'] ?? w.tags['busway:left'] ?? w.tags['busway:right'];
    if (w.tags['oneway:bus'] == 'no' ||
        w.tags['oneway:psv'] == 'no' ||
        busway == 'opposite_lane' ||
        busway == 'opposite_track') {
      backward = true;
    }
  }
  return (forward, backward);
}

const _cellDegrees = 0.002; // ~220 m
const _edgeServiceBit = 1;
const _edgeReverseBit = 2;

class EdgeHit {
  const EdgeHit(this.edge, this.metres, this.fraction, this.lat, this.lon);
  final int edge;
  final double metres;

  /// 0..1 along the edge, from `edgeFrom` to `edgeTo`.
  final double fraction;
  final double lat, lon;
}

class RoadGraph {
  RoadGraph._(this.mode, this.nodeLat, this.nodeLon, this.edgeFrom, this.edgeTo,
      this.edgeWay, this.edgeLen, this.edgeFlags, this._offset, this._adj,
      this._grid);

  final GraphMode mode;
  final Float64List nodeLat, nodeLon;
  final Int32List edgeFrom, edgeTo;
  final Int64List edgeWay;
  final Float32List edgeLen;
  final Uint8List edgeFlags;
  final Int32List _offset, _adj;
  final Map<int, Int32List> _grid;

  int get nodeCount => nodeLat.length;
  int get edgeCount => edgeFrom.length;

  bool isService(int edge) => edgeFlags[edge] & _edgeServiceBit != 0;

  /// True when the edge runs against its OSM way's own point order.
  bool isReversed(int edge) => edgeFlags[edge] & _edgeReverseBit != 0;

  /// Outgoing edge ids of [node].
  Iterable<int> edgesFrom(int node) =>
      _adj.getRange(_offset[node], _offset[node + 1]);

  static RoadGraph build(Iterable<OsmWay> ways, GraphMode mode) =>
      RoadGraphBuilder(mode).addAll(ways).build();

  /// Edges whose geometry passes within [metres] of the point.
  List<EdgeHit> near(double lat, double lon, double metres) {
    final span = (metres / 111000 / _cellDegrees).ceil() + 1;
    final baseLat = (lat / _cellDegrees).floor();
    final baseLon = (lon / _cellDegrees).floor();
    final out = <EdgeHit>[];
    final seen = <int>{};
    for (var dy = -span; dy <= span; dy++) {
      for (var dx = -span; dx <= span; dx++) {
        final cell = _grid[(baseLat + dy) * 1000000 + (baseLon + dx)];
        if (cell == null) continue;
        for (final e in cell) {
          if (!seen.add(e)) continue;
          final hit = _project(e, lat, lon);
          if (hit.metres <= metres) out.add(hit);
        }
      }
    }
    out.sort((a, b) => a.metres.compareTo(b.metres));
    return out;
  }

  EdgeHit _project(int edge, double lat, double lon) {
    final a = edgeFrom[edge], b = edgeTo[edge];
    final scale = math.cos(lat * math.pi / 180);
    final ax = nodeLon[a] * scale, ay = nodeLat[a];
    final bx = nodeLon[b] * scale, by = nodeLat[b];
    final px = lon * scale, py = lat;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final cy = ay + dy * t, cx = ax + dx * t;
    return EdgeHit(edge, haversineMetres(lat, lon, cy, cx / scale), t, cy,
        cx / scale);
  }

  /// Metres from the point to the closest point of edge [edge].
  double distanceToEdge(int edge, double lat, double lon) =>
      _project(edge, lat, lon).metres;

  /// Compass bearing of the edge, degrees.
  double bearingOf(int edge) => bearingBetween(nodeLat[edgeFrom[edge]],
      nodeLon[edgeFrom[edge]], nodeLat[edgeTo[edge]], nodeLon[edgeTo[edge]]);
}

double bearingBetween(double lat1, double lon1, double lat2, double lon2) {
  const toRad = math.pi / 180;
  final y = math.sin((lon2 - lon1) * toRad) * math.cos(lat2 * toRad);
  final x = math.cos(lat1 * toRad) * math.sin(lat2 * toRad) -
      math.sin(lat1 * toRad) * math.cos(lat2 * toRad) * math.cos((lon2 - lon1) * toRad);
  final deg = math.atan2(y, x) / toRad;
  return (deg + 360) % 360;
}

/// Smallest absolute difference between two bearings, 0..180.
double bearingDelta(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

class RoadGraphBuilder {
  RoadGraphBuilder(this.mode);
  final GraphMode mode;

  final _nodeIds = <int, int>{};
  final _lat = <double>[];
  final _lon = <double>[];
  final _from = <int>[];
  final _to = <int>[];
  final _way = <int>[];
  final _len = <double>[];
  final _flags = <int>[];
  final _seenWays = <int>{};

  int _node(double lat, double lon) {
    // Exact coordinate identity, as Overpass stores it (7 decimals).
    final key = (lat * 1e7).round() * 4294967296 + (lon * 1e7).round();
    final existing = _nodeIds[key];
    if (existing != null) return existing;
    final id = _lat.length;
    _nodeIds[key] = id;
    _lat.add(lat);
    _lon.add(lon);
    return id;
  }

  RoadGraphBuilder addAll(Iterable<OsmWay> ways) {
    for (final w in ways) {
      add(w);
    }
    return this;
  }

  void add(OsmWay w) {
    if (!wayInMode(w, mode)) return;
    // Overlapping Overpass tiles repeat whole ways.
    if (!_seenWays.add(w.id)) return;
    final (forward, backward) = wayDirections(w, mode);
    if (!forward && !backward) return;
    final service = w.tags['highway'] == 'service' ? _edgeServiceBit : 0;
    for (var i = 0; i + 1 < w.lat.length; i++) {
      final a = _node(w.lat[i], w.lon[i]);
      final b = _node(w.lat[i + 1], w.lon[i + 1]);
      if (a == b) continue;
      final metres =
          haversineMetres(w.lat[i], w.lon[i], w.lat[i + 1], w.lon[i + 1]);
      if (forward) _edge(a, b, w.id, metres, service);
      if (backward) _edge(b, a, w.id, metres, service | _edgeReverseBit);
    }
  }

  void _edge(int a, int b, int wayId, double metres, int flags) {
    _from.add(a);
    _to.add(b);
    _way.add(wayId);
    _len.add(metres);
    _flags.add(flags);
  }

  RoadGraph build() {
    final n = _lat.length, m = _from.length;
    final offset = Int32List(n + 1);
    for (final f in _from) {
      offset[f + 1]++;
    }
    for (var i = 0; i < n; i++) {
      offset[i + 1] += offset[i];
    }
    final cursor = Int32List.fromList(offset.sublist(0, n));
    final adj = Int32List(m);
    for (var e = 0; e < m; e++) {
      adj[cursor[_from[e]]++] = e;
    }

    final cells = <int, List<int>>{};
    for (var e = 0; e < m; e++) {
      final a = _from[e], b = _to[e];
      final loLat = math.min(_lat[a], _lat[b]), hiLat = math.max(_lat[a], _lat[b]);
      final loLon = math.min(_lon[a], _lon[b]), hiLon = math.max(_lon[a], _lon[b]);
      for (var y = (loLat / _cellDegrees).floor();
          y <= (hiLat / _cellDegrees).floor();
          y++) {
        for (var x = (loLon / _cellDegrees).floor();
            x <= (hiLon / _cellDegrees).floor();
            x++) {
          (cells[y * 1000000 + x] ??= <int>[]).add(e);
        }
      }
    }
    final grid = {
      for (final entry in cells.entries)
        entry.key: Int32List.fromList(entry.value)
    };

    return RoadGraph._(
      mode,
      Float64List.fromList(_lat),
      Float64List.fromList(_lon),
      Int32List.fromList(_from),
      Int32List.fromList(_to),
      Int64List.fromList(_way),
      Float32List.fromList(_len),
      Uint8List.fromList(_flags),
      offset,
      adj,
      grid,
    );
  }
}
