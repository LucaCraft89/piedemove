/// OSM -> pedestrian graph. Pure Dart; `tool/build_walk.dart` is the CLI.
///
/// General rules over OSM tags only: nothing here knows a way id, a street or
/// a coordinate. The model (docs/walk_routing.md):
///
/// * Dedicated ways (footway, path, pedestrian, track, steps, corridor) are
///   edges as mapped; `footway=crossing` ways are crossing edges typed by
///   their tags.
/// * Minor streets (residential, living_street, unclassified, service) are
///   walked on the carriageway (their centreline).
/// * Busy roads (tertiary and up) get a generated sidewalk on each side, so a
///   walker is always on one side. At every junction of such roads the arms
///   are ordered by bearing and a *corner* node sits between each pair; the
///   two corners of an arm are joined by a crossing edge typed by the node
///   tags (signals / zebra / uncontrolled) or, untagged, as an unmarked
///   crossing (heavily penalised, keeps the graph connected).
/// * Never walkable: motorways without foot=yes, foot=no, access=private/no,
///   construction, rail. No crossing edge is ever generated across them.
library;

import 'dart:math' as math;

import 'walk_graph.dart';

/// Half the carriageway plus verge: where the generated sidewalk sits.
const walkSideOffsetMetres = 6.0;

/// Simplification tolerance for edge geometry.
const walkSimplifyMetres = 0.7;

/// Components smaller than this (edges) are unreachable islands: dropped.
const walkMinComponentEdges = 20;

const _mLat = 111194.9266;

class OsmNode {
  OsmNode(this.lat, this.lon, this.cross);
  final double lat, lon;

  /// [WalkCrossing] type, or -1 for a plain node.
  final int cross;
}

class OsmWay {
  OsmWay(this.id, this.nodes, this.tags);
  final int id;
  final List<int> nodes;
  final Map<String, String> tags;
}

class OsmData {
  final nodes = <int, OsmNode>{};
  final ways = <int, OsmWay>{};

  /// Oldest `timestamp_osm_base` among the merged responses (unix seconds).
  int timestamp = 0;

  /// Merges one Overpass JSON response (decoded). Repeated ids are ignored,
  /// so overlapping tiles are harmless.
  void addOverpass(Map<String, dynamic> json) {
    final ts = (json['osm3s'] as Map?)?['timestamp_osm_base'] as String?;
    if (ts != null) {
      final t = DateTime.tryParse(ts)?.millisecondsSinceEpoch;
      if (t != null && (timestamp == 0 || t ~/ 1000 < timestamp)) {
        timestamp = t ~/ 1000;
      }
    }
    for (final e in (json['elements'] as List)) {
      final m = e as Map<String, dynamic>;
      final id = m['id'] as int;
      if (m['type'] == 'node') {
        if (nodes.containsKey(id)) continue;
        final tags = (m['tags'] as Map?)?.cast<String, String>();
        nodes[id] = OsmNode((m['lat'] as num).toDouble(),
            (m['lon'] as num).toDouble(), nodeCrossing(tags));
      } else if (m['type'] == 'way') {
        if (ways.containsKey(id)) continue;
        ways[id] = OsmWay(
          id,
          [for (final n in m['nodes'] as List) n as int],
          (m['tags'] as Map?)?.cast<String, String>() ?? const {},
        );
      }
    }
  }
}

/// Overpass-shaped JSON from `osmium cat -f opl` text (nodes with x/y, ways
/// with N refs, tags percent-escaped). Lets Geofabrik extracts feed
/// [OsmData.addOverpass]. `osm3s` = newest object timestamp, the PBF's age.
Map<String, dynamic> oplToOverpass(Iterable<String> lines) {
  String dec(String s) => s.contains('%')
      ? s.replaceAllMapped(RegExp(r'%([0-9a-fA-F]+)%'),
          (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
      : s;
  final elements = <Map<String, dynamic>>[];
  var newest = '';
  for (final line in lines) {
    if (line.length < 2 || (line[0] != 'n' && line[0] != 'w')) continue;
    final f = line.split(' ');
    final isNode = line[0] == 'n';
    final e = <String, dynamic>{
      'type': isNode ? 'node' : 'way',
      'id': int.parse(f[0].substring(1)),
    };
    var located = !isNode;
    for (final t in f.skip(1)) {
      if (t.isEmpty) continue;
      final v = t.substring(1);
      switch (t[0]) {
        case 't':
          if (v.compareTo(newest) > 0) newest = v;
        case 'x':
          e['lon'] = double.parse(v);
        case 'y':
          e['lat'] = double.parse(v);
          located = true;
        case 'N':
          e['nodes'] = [for (final r in v.split(',')) if (r.isNotEmpty) int.parse(r.substring(1))];
        case 'T':
          e['tags'] = {
            for (final kv in v.split(',')) if (kv.contains('='))
              dec(kv.substring(0, kv.indexOf('='))): dec(kv.substring(kv.indexOf('=') + 1))
          };
      }
    }
    if (located && (!isNode || e.containsKey('lon'))) elements.add(e);
  }
  return {
    if (newest.isNotEmpty) 'osm3s': {'timestamp_osm_base': newest},
    'elements': elements,
  };
}

extension OsmClip on OsmData {
  /// Keeps only the ways with at least one node inside the box (and their
  /// nodes): tiles overlap the bbox edge, and a far-off way is dead weight.
  void clipTo(double south, double west, double north, double east) {
    bool inside(int id) {
      final n = nodes[id];
      return n != null &&
          n.lat >= south &&
          n.lat <= north &&
          n.lon >= west &&
          n.lon <= east;
    }

    ways.removeWhere((_, w) => !w.nodes.any(inside));
    final used = <int>{for (final w in ways.values) ...w.nodes};
    nodes.removeWhere((id, _) => !used.contains(id));
  }
}

/// Crossing type of a node's tags, -1 when the node is not a crossing.
int nodeCrossing(Map<String, String>? t) {
  if (t == null) return -1;
  final hw = t['highway'];
  if (hw != 'crossing' && hw != 'traffic_signals' && t['crossing'] == null) {
    return -1;
  }
  final c = crossingType(t);
  if (c != null) return c;
  return hw == 'traffic_signals' ? WalkCrossing.signals : WalkCrossing.uncontrolled;
}

/// [WalkCrossing] type named by crossing tags, null when they say nothing.
int? crossingType(Map<String, String> t) {
  final c = t['crossing'];
  if (c == 'traffic_signals' || t['crossing:signals'] == 'yes') {
    return WalkCrossing.signals;
  }
  if (c == 'zebra' || t['crossing_ref'] == 'zebra' || t['crossing:markings'] == 'zebra') {
    return WalkCrossing.zebra;
  }
  if (c == 'marked' || c == 'uncontrolled') return WalkCrossing.uncontrolled;
  if (c == 'unmarked') return WalkCrossing.unmarked;
  return null;
}

/// What a way is, in graph terms.
class WayClass {
  const WayClass({
    required this.kind,
    this.sub = 0,
    this.sided = false,
    this.left = 0,
    this.right = 0,
    this.covered = false,
    this.name,
  });
  final int kind;
  final int sub;

  /// A busy road: sidewalks are generated on both sides.
  final bool sided;

  /// Sidewalk state on the left / right of the way direction:
  /// 0 unknown, 1 present, 2 none.
  final int left, right;
  final bool covered;
  final String? name;
}

int _sidewalkState(String? v) => switch (v) {
      'yes' || 'both' || 'left' || 'right' || 'separate' => 1,
      'no' || 'none' => 2,
      _ => 0,
    };

/// Classifies a way from its tags; null = not walkable.
WayClass? classifyWay(Map<String, String> t) {
  final hw = t['highway'];
  if (hw == null) return null;
  final foot = t['foot'];
  final footYes = foot == 'yes' || foot == 'designated' || foot == 'permissive';
  if (foot == 'no' || foot == 'private') return null;
  final access = t['access'];
  if ((access == 'no' || access == 'private') && !footYes) return null;
  if (t['construction'] != null || t['proposed'] != null) return null;

  final covered = t['covered'] == 'yes' ||
      t['covered'] == 'arcade' ||
      t['tunnel'] == 'building_passage' ||
      t['tunnel'] == 'arcade' ||
      t['indoor'] == 'yes';
  final name = t['name'];

  WayClass path(int sub) =>
      WayClass(kind: WalkKind.path, sub: sub, covered: covered, name: name);

  switch (hw) {
    case 'footway':
    case 'path':
    case 'corridor':
    case 'cycleway':
      if (hw == 'cycleway' && !footYes) return null;
      final fw = t['footway'], cw = t['cycleway'];
      if (fw == 'crossing' || cw == 'crossing') {
        return WayClass(
          kind: WalkKind.crossing,
          sub: crossingType(t) ?? WalkCrossing.uncontrolled,
          covered: covered,
          name: name,
        );
      }
      return path(fw == 'sidewalk' ? 1 : 0);
    case 'pedestrian':
      return path(2);
    case 'track':
      return path(3);
    case 'steps':
      return WayClass(kind: WalkKind.steps, covered: covered, name: name);
    case 'bridleway':
      return null;
  }

  // Roads. Tunnels without any pedestrian provision are not for walking.
  final sw = t['sidewalk'];
  var left = _sidewalkState(t['sidewalk:left'] ?? t['sidewalk:both'] ?? sw);
  var right = _sidewalkState(t['sidewalk:right'] ?? t['sidewalk:both'] ?? sw);
  if (sw == 'left') right = t['sidewalk:right'] == null ? 2 : right;
  if (sw == 'right') left = t['sidewalk:left'] == null ? 2 : left;
  if (t['tunnel'] == 'yes' && left != 1 && right != 1 && !footYes) return null;

  int? roadClass;
  switch (hw) {
    case 'tertiary':
    case 'tertiary_link':
      roadClass = 0;
    case 'secondary':
    case 'secondary_link':
      roadClass = 1;
    case 'primary':
    case 'primary_link':
    case 'trunk':
    case 'trunk_link':
      roadClass = 2;
    case 'motorway':
    case 'motorway_link':
      if (!footYes) return null;
      roadClass = 2;
  }
  if (roadClass != null) {
    return WayClass(
      kind: WalkKind.side,
      sub: roadClass,
      sided: true,
      left: left,
      right: right,
      covered: covered,
      name: name,
    );
  }
  switch (hw) {
    case 'living_street':
      return WayClass(kind: WalkKind.street, sub: 1, covered: covered, name: name);
    case 'residential':
    case 'unclassified':
    case 'road':
      return WayClass(kind: WalkKind.street, covered: covered, name: name);
    case 'service':
      final s = t['service'];
      final aisle = s == 'parking_aisle' || s == 'driveway' || s == 'drive-through';
      return WayClass(
          kind: WalkKind.street, sub: aisle ? 2 : 0, covered: covered, name: name);
  }
  return null;
}

// -- builder -----------------------------------------------------------------

class _W {
  _W(this.way, this.cls, this.nodes);
  final OsmWay way;
  final WayClass cls;
  final List<int> nodes;
}

class _Seg {
  _Seg(this.w, this.nodes);
  final _W w;
  final List<int> nodes; // OSM node ids, first and last are junctions
}

class _Arm {
  _Arm(this.seg, this.end, this.angle, this.sided);
  final int seg;
  final int end; // 0 start, 1 end
  final double angle;
  final bool sided;
}

class _TE {
  _TE(this.a, this.b, this.flags, this.name, this.geom);
  int a, b;
  final int flags;
  final String? name;
  final List<double> geom; // flat lat, lon
  bool dead = false;
}

/// Builds the graph for [bbox] = (south, west, north, east) in degrees.
WalkGraph buildWalkGraph(OsmData data,
    {required double south,
    required double west,
    required double north,
    required double east,
    int minComponentEdges = walkMinComponentEdges}) {
  final lat0 = (south + north) / 2, lon0 = (west + east) / 2;
  final mLon = _mLat * math.cos(lat0 * math.pi / 180);
  double px(double lon) => (lon - lon0) * mLon;
  double py(double lat) => (lat - lat0) * _mLat;
  double toLat(double y) => lat0 + y / _mLat;
  double toLon(double x) => lon0 + x / mLon;

  // 1. walkable ways, sorted by id for determinism
  final ways = <_W>[];
  final wayIds = data.ways.keys.toList()..sort();
  for (final id in wayIds) {
    final w = data.ways[id]!;
    final cls = classifyWay(w.tags);
    if (cls == null) continue;
    final nodes = <int>[];
    for (final n in w.nodes) {
      if (!data.nodes.containsKey(n)) continue;
      if (nodes.isNotEmpty && nodes.last == n) continue;
      nodes.add(n);
    }
    if (nodes.length < 2) continue;
    ways.add(_W(w, cls, nodes));
  }

  // A crossing way has no name of its own: it crosses the street it touches.
  final roadName = <int, String>{};
  for (final w in ways) {
    if (w.cls.name == null || (w.cls.kind != WalkKind.street && w.cls.kind != WalkKind.side)) {
      continue;
    }
    for (final n in w.nodes) {
      roadName.putIfAbsent(n, () => w.cls.name!);
    }
  }
  String? nameOf(_W w) {
    if (w.cls.name != null || w.cls.kind != WalkKind.crossing) return w.cls.name;
    for (final n in w.nodes) {
      final r = roadName[n];
      if (r != null) return r;
    }
    return null;
  }

  // 2. junctions: shared nodes, way ends, tagged crossings on busy roads.
  final uses = <int, int>{};
  for (final w in ways) {
    final crossing = w.cls.kind == WalkKind.crossing;
    for (var i = 0; i < w.nodes.length; i++) {
      final end = i == 0 || i == w.nodes.length - 1;
      if (crossing && !end) continue; // a crossing edge skips the road nodes
      uses[w.nodes[i]] = (uses[w.nodes[i]] ?? 0) + 1;
    }
  }
  bool junction(_W w, int i) {
    final n = w.nodes[i];
    if (i == 0 || i == w.nodes.length - 1) return true;
    if ((uses[n] ?? 0) >= 2) return true;
    return w.cls.sided && data.nodes[n]!.cross >= 0;
  }

  // 3. segments
  final segs = <_Seg>[];
  for (final w in ways) {
    if (w.cls.kind == WalkKind.crossing) {
      segs.add(_Seg(w, [w.nodes.first, w.nodes.last]));
      continue;
    }
    var start = 0;
    for (var i = 1; i < w.nodes.length; i++) {
      if (junction(w, i)) {
        segs.add(_Seg(w, w.nodes.sublist(start, i + 1)));
        start = i;
      }
    }
  }

  // 4. arms per junction node
  final arms = <int, List<_Arm>>{};
  double angleOf(_Seg s, int end) {
    final ids = end == 0 ? s.nodes : s.nodes.reversed.toList();
    final o = data.nodes[ids.first]!;
    for (var i = 1; i < ids.length; i++) {
      final p = data.nodes[ids[i]]!;
      final dx = px(p.lon) - px(o.lon), dy = py(p.lat) - py(o.lat);
      if (dx * dx + dy * dy > 0.25) return math.atan2(dy, dx);
    }
    return 0;
  }

  for (var s = 0; s < segs.length; s++) {
    final seg = segs[s];
    for (final end in [0, 1]) {
      final n = end == 0 ? seg.nodes.first : seg.nodes.last;
      arms
          .putIfAbsent(n, () => [])
          .add(_Arm(s, end, angleOf(seg, end), seg.w.cls.sided));
    }
  }

  // 5. output nodes and per-arm attachment
  final outLat = <double>[], outLon = <double>[];
  int emit(double lat, double lon) {
    outLat.add(lat);
    outLon.add(lon);
    return outLat.length - 1;
  }

  final attach = List.generate(segs.length, (_) => [-1, -1]); // non-sided
  final armL = List.generate(segs.length, (_) => [-1, -1]);
  final armR = List.generate(segs.length, (_) => [-1, -1]);
  final edges = <_TE>[];
  const d = walkSideOffsetMetres;

  final junctionIds = arms.keys.toList()..sort();
  for (final n in junctionIds) {
    final list = arms[n]!;
    final on = data.nodes[n]!;
    final sided = list.where((a) => a.sided).toList()
      ..sort((a, b) {
        final c = a.angle.compareTo(b.angle);
        return c != 0 ? c : (a.seg != b.seg ? a.seg.compareTo(b.seg) : a.end.compareTo(b.end));
      });
    final k = sided.length;
    if (k <= 1) {
      final id = emit(on.lat, on.lon);
      for (final a in list) {
        if (a.sided) {
          armL[a.seg][a.end] = id;
          armR[a.seg][a.end] = id;
        } else {
          attach[a.seg][a.end] = id;
        }
      }
      continue;
    }
    final cx = px(on.lon), cy = py(on.lat);
    final corners = <int>[];
    for (var i = 0; i < k; i++) {
      final a = sided[i], b = sided[(i + 1) % k];
      final vx = -math.sin(a.angle) + math.sin(b.angle);
      final vy = math.cos(a.angle) - math.cos(b.angle);
      final m2 = vx * vx + vy * vy;
      double ox, oy;
      if (m2 < 0.09) {
        ox = -math.sin(a.angle) * d;
        oy = math.cos(a.angle) * d;
      } else {
        final len = math.min(2 * d / math.sqrt(m2), 2.5 * d);
        final m = math.sqrt(m2);
        ox = vx / m * len;
        oy = vy / m * len;
      }
      corners.add(emit(toLat(cy + oy), toLon(cx + ox)));
    }
    for (var i = 0; i < k; i++) {
      armL[sided[i].seg][sided[i].end] = corners[i];
      armR[sided[i].seg][sided[i].end] = corners[(i - 1 + k) % k];
    }
    for (final a in list) {
      if (a.sided) continue;
      var ci = k - 1;
      for (var i = 0; i < k; i++) {
        if (sided[i].angle <= a.angle) ci = i;
      }
      attach[a.seg][a.end] = corners[ci];
    }
    // crossings of each arm, when this is a real junction or a tagged node
    final real = list.length > k || k >= 3 || on.cross >= 0;
    if (real) {
      final type = on.cross >= 0 ? on.cross : WalkCrossing.unmarked;
      for (var i = 0; i < (k == 2 ? 1 : k); i++) {
        final name = segs[sided[i].seg].w.cls.name;
        edges.add(_TE(corners[(i - 1 + k) % k], corners[i],
            WalkFlags.make(WalkKind.crossing, sub: type), name, const []));
      }
    }
  }

  // 6. edges
  List<double> interior(_Seg s, {int side = 0}) {
    // flat lat, lon of the interior points, offset to a side (+1 left, -1 right)
    final pts = <List<double>>[
      for (final id in s.nodes) [px(data.nodes[id]!.lon), py(data.nodes[id]!.lat)]
    ];
    final out = <double>[];
    for (var j = 1; j < pts.length - 1; j++) {
      var x = pts[j][0], y = pts[j][1];
      if (side != 0) {
        double ux0 = x - pts[j - 1][0], uy0 = y - pts[j - 1][1];
        double ux1 = pts[j + 1][0] - x, uy1 = pts[j + 1][1] - y;
        final l0 = math.sqrt(ux0 * ux0 + uy0 * uy0), l1 = math.sqrt(ux1 * ux1 + uy1 * uy1);
        if (l0 < 1e-6 || l1 < 1e-6) continue;
        ux0 /= l0;
        uy0 /= l0;
        ux1 /= l1;
        uy1 /= l1;
        final vx = -uy0 - uy1, vy = ux0 + ux1; // sum of left normals
        final m2 = vx * vx + vy * vy;
        double ox, oy;
        if (m2 < 0.09) {
          ox = -uy0 * d;
          oy = ux0 * d;
        } else {
          final m = math.sqrt(m2);
          final len = math.min(2 * d / m, 2.5 * d);
          ox = vx / m * len;
          oy = vy / m * len;
        }
        x += side * ox;
        y += side * oy;
      }
      out..add(toLat(y))..add(toLon(x));
    }
    return out;
  }

  for (var s = 0; s < segs.length; s++) {
    final seg = segs[s];
    final c = seg.w.cls;
    if (c.sided) {
      int base(int sw) => WalkFlags.make(WalkKind.side,
          sub: c.sub, sidewalk: sw, covered: c.covered);
      edges.add(_TE(armL[s][0], armR[s][1], base(c.left), c.name,
          interior(seg, side: 1)));
      edges.add(_TE(armR[s][0], armL[s][1], base(c.right), c.name,
          interior(seg, side: -1)));
    } else {
      edges.add(_TE(
          attach[s][0],
          attach[s][1],
          WalkFlags.make(c.kind, sub: c.sub, covered: c.covered),
          nameOf(seg.w),
          seg.w.cls.kind == WalkKind.crossing ? const [] : interior(seg)));
    }
  }

  // 7. contract pass-through nodes with identical attributes
  final adj = List.generate(outLat.length, (_) => <int>[]);
  for (var i = 0; i < edges.length; i++) {
    adj[edges[i].a].add(i);
    if (edges[i].b != edges[i].a) adj[edges[i].b].add(i);
  }
  for (var n = 0; n < outLat.length; n++) {
    final inc = [for (final e in adj[n]) if (!edges[e].dead) e];
    if (inc.length != 2) continue;
    final e1 = edges[inc[0]], e2 = edges[inc[1]];
    if (e1.a == e1.b || e2.a == e2.b) continue;
    if (e1.flags != e2.flags || e1.name != e2.name) continue;
    if (WalkFlags.kind(e1.flags) == WalkKind.crossing) continue;
    final o1 = e1.a == n ? e1.b : e1.a, o2 = e2.a == n ? e2.b : e2.a;
    if (o1 == o2) continue;
    List<double> oriented(_TE e, bool fromOther) {
      // geometry running other -> n when fromOther, else n -> other
      final g = e.a == n ? (fromOther ? _reverse(e.geom) : e.geom) : (fromOther ? e.geom : _reverse(e.geom));
      return g;
    }

    final merged = _TE(o1, o2, e1.flags, e1.name, [
      ...oriented(e1, true),
      outLat[n],
      outLon[n],
      ...oriented(e2, false),
    ]);
    e1.dead = true;
    e2.dead = true;
    edges.add(merged);
    final id = edges.length - 1;
    adj[o1]
      ..remove(inc[0])
      ..remove(inc[1])
      ..add(id);
    adj[o2]
      ..remove(inc[0])
      ..remove(inc[1])
      ..add(id);
    adj[n].clear();
  }

  // 8. drop tiny islands, then quantise
  final live = [for (final e in edges) if (!e.dead && e.a != e.b) e];
  final parent = List<int>.generate(outLat.length, (i) => i);
  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  for (final e in live) {
    parent[find(e.a)] = find(e.b);
  }
  final count = <int, int>{};
  for (final e in live) {
    count[find(e.a)] = (count[find(e.a)] ?? 0) + 1;
  }
  final kept = [for (final e in live) if (count[find(e.a)]! >= minComponentEdges) e];

  final remap = <int, int>{};
  final nLat = <int>[], nLon = <int>[];
  int q(double v) => (v * walkCoordScale).round();
  int nodeOf(int i) => remap.putIfAbsent(i, () {
        nLat.add(q(outLat[i]));
        nLon.add(q(outLon[i]));
        return nLat.length - 1;
      });
  final specs = <WalkEdgeSpec>[];
  for (final e in kept) {
    final a = nodeOf(e.a), b = nodeOf(e.b);
    final g = _simplify(e.geom, lat0, mLon);
    specs.add(WalkEdgeSpec(a, b, e.flags,
        name: e.name, geom: [for (var i = 0; i < g.length; i++) q(g[i])]));
  }
  return WalkGraph.build(
    nodeLat: nLat,
    nodeLon: nLon,
    edges: specs,
    osmTime: data.timestamp,
    bbox: [q(south), q(west), q(north), q(east)],
  );
}

List<double> _reverse(List<double> g) {
  final r = <double>[];
  for (var i = g.length - 2; i >= 0; i -= 2) {
    r..add(g[i])..add(g[i + 1]);
  }
  return r;
}

/// Douglas-Peucker on the flat lat/lon list (interior points only).
List<double> _simplify(List<double> g, double lat0, double mLon) {
  final n = g.length ~/ 2;
  if (n <= 2) return g;
  final keep = List<bool>.filled(n, false);
  final stack = <(int, int)>[(0, n - 1)];
  keep[0] = keep[n - 1] = true;
  double x(int i) => g[i * 2 + 1] * mLon;
  double y(int i) => g[i * 2] * _mLat;
  while (stack.isNotEmpty) {
    final (lo, hi) = stack.removeLast();
    var worst = -1.0;
    var wi = -1;
    final dx = x(hi) - x(lo), dy = y(hi) - y(lo);
    final len2 = dx * dx + dy * dy;
    for (var i = lo + 1; i < hi; i++) {
      double dist;
      if (len2 == 0) {
        dist = math.sqrt(math.pow(x(i) - x(lo), 2) + math.pow(y(i) - y(lo), 2));
      } else {
        final t = (((x(i) - x(lo)) * dx + (y(i) - y(lo)) * dy) / len2).clamp(0.0, 1.0);
        dist = math.sqrt(math.pow(x(i) - (x(lo) + t * dx), 2) +
            math.pow(y(i) - (y(lo) + t * dy), 2));
      }
      if (dist > worst) {
        worst = dist;
        wi = i;
      }
    }
    if (worst > walkSimplifyMetres) {
      keep[wi] = true;
      stack..add((lo, wi))..add((wi, hi));
    }
  }
  final out = <double>[];
  for (var i = 0; i < n; i++) {
    if (keep[i]) out..add(g[i * 2])..add(g[i * 2 + 1]);
  }
  return out;
}
