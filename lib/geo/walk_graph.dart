/// The versioned pedestrian graph: model, binary codec, header.
///
/// One format for every source (shipped asset, downloaded update, test
/// fixture). Pure Dart, no Flutter: `tool/build_walk.dart` writes it, the app
/// and the tests read it.
///
/// File = header + payload.
///
///     "PMWG"            4   magic
///     u16 format        2   [walkGraphFormat]
///     u16 0             2   reserved
///     i64 osmTime       8   unix seconds of the OSM data
///     i32 x4            16  bbox minLat, minLon, maxLat, maxLon (1e-5 deg)
///     u32 payloadLen    4
///     sha256(payload)   32
///     payload
///
/// Payload (varints, LEB128; zig = zigzag):
///
///     nNames, {len, utf8}
///     nNodes, nodes sorted by (lat, lon): lat delta, zig lon delta   (1e-5 deg)
///     nEdges, edges sorted by (a, b): a delta, zig(b - a), flags u8,
///             name+1, nGeom, {zig dlat, zig dlon} from the previous point
///             (the first from node a)
///
/// An edge is undirected, `a <= b`, geometry runs a -> b.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const walkGraphFormat = 1;
const _magic = [0x50, 0x4d, 0x57, 0x47]; // PMWG
const walkHeaderBytes = 68;

/// 1e-5 degree units per degree.
const walkCoordScale = 100000.0;
const _metresPerDegree = 111194.9266;

class WalkKind {
  static const path = 0; // footway, path, pedestrian, track, corridor
  static const street = 1; // minor street walked on the carriageway
  static const side = 2; // generated sidewalk of a busy road
  static const steps = 3;
  static const crossing = 4; // explicit crossing (way or generated)
}

class WalkCrossing {
  static const signals = 0;
  static const zebra = 1;
  static const uncontrolled = 2;
  static const unmarked = 3;
}

/// Flags byte: kind (3 bits) | sub (2) | sidewalk state (2) | covered (1).
/// [sub] is the path kind / street kind / road class / crossing type.
class WalkFlags {
  static int make(int kind, {int sub = 0, int sidewalk = 0, bool covered = false}) =>
      kind | (sub << 3) | (sidewalk << 5) | (covered ? 128 : 0);
  static int kind(int f) => f & 7;
  static int sub(int f) => (f >> 3) & 3;
  static int sidewalk(int f) => (f >> 5) & 3;
  static bool covered(int f) => f & 128 != 0;
}

class WalkFormatException implements Exception {
  WalkFormatException(this.message, {this.incompatible = false});
  final String message;

  /// A well-formed file from a newer/older format: ignore it, do not report.
  final bool incompatible;
  @override
  String toString() => 'WalkFormatException: $message';
}

class WalkHeader {
  const WalkHeader({
    required this.format,
    required this.osmTime,
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
    required this.payloadLength,
    required this.payloadSha256,
  });

  final int format;
  final int osmTime;

  /// bbox in 1e-5 degrees.
  final int minLat, minLon, maxLat, maxLon;
  final int payloadLength;
  final List<int> payloadSha256;

  DateTime get osmDate =>
      DateTime.fromMillisecondsSinceEpoch(osmTime * 1000, isUtc: true);

  String get sha256Hex =>
      payloadSha256.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  bool covers(double lat, double lon) =>
      lat * walkCoordScale >= minLat &&
      lat * walkCoordScale <= maxLat &&
      lon * walkCoordScale >= minLon &&
      lon * walkCoordScale <= maxLon;

  /// Reads and checks the fixed header. Throws [WalkFormatException].
  static WalkHeader parse(Uint8List file) {
    if (file.length < walkHeaderBytes) {
      throw WalkFormatException('truncated header');
    }
    for (var i = 0; i < 4; i++) {
      if (file[i] != _magic[i]) throw WalkFormatException('bad magic');
    }
    final b = ByteData.sublistView(file);
    final format = b.getUint16(4, Endian.little);
    if (format != walkGraphFormat) {
      throw WalkFormatException('format $format, this app reads $walkGraphFormat',
          incompatible: true);
    }
    return WalkHeader(
      format: format,
      osmTime: b.getInt64(8, Endian.little),
      minLat: b.getInt32(16, Endian.little),
      minLon: b.getInt32(20, Endian.little),
      maxLat: b.getInt32(24, Endian.little),
      maxLon: b.getInt32(28, Endian.little),
      payloadLength: b.getUint32(32, Endian.little),
      payloadSha256: Uint8List.sublistView(file, 36, 68),
    );
  }
}

/// One edge as the builder hands it over. [geom] is flat `lat, lon` pairs in
/// 1e-5 degrees, the intermediate points between the end nodes.
class WalkEdgeSpec {
  WalkEdgeSpec(this.a, this.b, this.flags, {this.name, List<int>? geom})
      : geom = geom ?? <int>[];
  int a, b;
  final int flags;
  final String? name;
  List<int> geom;
}

class WalkGraph {
  WalkGraph._({
    required this.header,
    required this.nodeLat,
    required this.nodeLon,
    required this.edgeA,
    required this.edgeB,
    required this.edgeFlags,
    required this.edgeName,
    required this.geomStart,
    required this.geomLat,
    required this.geomLon,
    required this.names,
  })  : nodeCount = nodeLat.length,
        edgeCount = edgeA.length,
        edgeLen = Float32List(edgeA.length) {
    _derive();
  }

  final WalkHeader header;
  final Int32List nodeLat, nodeLon;
  final Int32List edgeA, edgeB;
  final Uint8List edgeFlags;
  final Int32List edgeName; // -1 none
  final Int32List geomStart; // edgeCount + 1
  final Int32List geomLat, geomLon;
  final List<String> names;
  final int nodeCount, edgeCount;

  /// True metres of each edge along its geometry.
  final Float32List edgeLen;

  /// Edges incident to each node (CSR).
  late final Int32List adjStart;
  late final Int32List adjEdge;

  /// Connected-component id per node, and the size (edges) of each component.
  late final Int32List component;
  late final List<int> componentEdges;

  double lat(int node) => nodeLat[node] / walkCoordScale;
  double lon(int node) => nodeLon[node] / walkCoordScale;

  /// Edge [e]'s points `a, geometry..., b` as flat 1e-5 degree pairs, reversed
  /// when [forward] is false.
  Int32List points(int e, {bool forward = true}) {
    final g0 = geomStart[e], g1 = geomStart[e + 1];
    final n = g1 - g0 + 2;
    final out = Int32List(n * 2);
    out[0] = nodeLat[edgeA[e]];
    out[1] = nodeLon[edgeA[e]];
    for (var i = 0; i < g1 - g0; i++) {
      out[2 + i * 2] = geomLat[g0 + i];
      out[3 + i * 2] = geomLon[g0 + i];
    }
    out[n * 2 - 2] = nodeLat[edgeB[e]];
    out[n * 2 - 1] = nodeLon[edgeB[e]];
    if (forward) return out;
    final rev = Int32List(n * 2);
    for (var i = 0; i < n; i++) {
      rev[i * 2] = out[(n - 1 - i) * 2];
      rev[i * 2 + 1] = out[(n - 1 - i) * 2 + 1];
    }
    return rev;
  }

  int other(int e, int node) => edgeA[e] == node ? edgeB[e] : edgeA[e];

  void _derive() {
    for (var e = 0; e < edgeCount; e++) {
      final p = points(e);
      var len = 0.0;
      for (var i = 2; i < p.length; i += 2) {
        len += segMetres(p[i - 2], p[i - 1], p[i], p[i + 1]);
      }
      edgeLen[e] = len;
    }
    final deg = Int32List(nodeCount + 1);
    for (var e = 0; e < edgeCount; e++) {
      deg[edgeA[e] + 1]++;
      if (edgeB[e] != edgeA[e]) deg[edgeB[e] + 1]++;
    }
    for (var i = 0; i < nodeCount; i++) {
      deg[i + 1] += deg[i];
    }
    adjStart = deg;
    adjEdge = Int32List(deg[nodeCount]);
    final fill = Int32List.fromList(deg);
    for (var e = 0; e < edgeCount; e++) {
      adjEdge[fill[edgeA[e]]++] = e;
      if (edgeB[e] != edgeA[e]) adjEdge[fill[edgeB[e]]++] = e;
    }
    // Components by BFS: snapping ignores tiny islands (a routed path could
    // never leave them).
    component = Int32List(nodeCount)..fillRange(0, nodeCount, -1);
    final sizes = <int>[];
    final stack = <int>[];
    for (var s = 0; s < nodeCount; s++) {
      if (component[s] >= 0) continue;
      final id = sizes.length;
      var edges = 0;
      component[s] = id;
      stack.add(s);
      while (stack.isNotEmpty) {
        final n = stack.removeLast();
        for (var i = adjStart[n]; i < adjStart[n + 1]; i++) {
          final e = adjEdge[i];
          edges++;
          final o = other(e, n);
          if (component[o] < 0) {
            component[o] = id;
            stack.add(o);
          }
        }
      }
      sizes.add(edges ~/ 2);
    }
    componentEdges = sizes;
  }

  /// Canonical graph from builder output: nodes sorted by (lat, lon), edges by
  /// (a, b, ...), `a <= b`, so equal input gives identical bytes.
  factory WalkGraph.build({
    required List<int> nodeLat,
    required List<int> nodeLon,
    required List<WalkEdgeSpec> edges,
    required int osmTime,
    required List<int> bbox, // minLat, minLon, maxLat, maxLon
  }) {
    final order = List<int>.generate(nodeLat.length, (i) => i)
      ..sort((x, y) {
        final c = nodeLat[x].compareTo(nodeLat[y]);
        if (c != 0) return c;
        final d = nodeLon[x].compareTo(nodeLon[y]);
        return d != 0 ? d : x.compareTo(y);
      });
    final remap = Int32List(nodeLat.length);
    for (var i = 0; i < order.length; i++) {
      remap[order[i]] = i;
    }
    final specs = <WalkEdgeSpec>[];
    for (final e in edges) {
      var a = remap[e.a], b = remap[e.b];
      var geom = e.geom;
      if (a > b) {
        final t = a;
        a = b;
        b = t;
        final r = <int>[];
        for (var i = geom.length - 2; i >= 0; i -= 2) {
          r..add(geom[i])..add(geom[i + 1]);
        }
        geom = r;
      }
      specs.add(WalkEdgeSpec(a, b, e.flags, name: e.name, geom: geom));
    }
    int cmp(WalkEdgeSpec x, WalkEdgeSpec y) {
      var c = x.a.compareTo(y.a);
      if (c != 0) return c;
      c = x.b.compareTo(y.b);
      if (c != 0) return c;
      c = x.flags.compareTo(y.flags);
      if (c != 0) return c;
      c = (x.name ?? '').compareTo(y.name ?? '');
      if (c != 0) return c;
      c = x.geom.length.compareTo(y.geom.length);
      if (c != 0) return c;
      for (var i = 0; i < x.geom.length; i++) {
        c = x.geom[i].compareTo(y.geom[i]);
        if (c != 0) return c;
      }
      return 0;
    }

    specs.sort(cmp);
    final names = <String>[];
    final nameIx = <String, int>{};
    final edgeName = Int32List(specs.length);
    var geomTotal = 0;
    for (var i = 0; i < specs.length; i++) {
      final n = specs[i].name;
      edgeName[i] =
          n == null
              ? -1
              : nameIx.putIfAbsent(n, () {
                  names.add(n);
                  return names.length - 1;
                });
      geomTotal += specs[i].geom.length ~/ 2;
    }
    final gStart = Int32List(specs.length + 1);
    final gLat = Int32List(geomTotal), gLon = Int32List(geomTotal);
    var g = 0;
    for (var i = 0; i < specs.length; i++) {
      gStart[i] = g;
      final geom = specs[i].geom;
      for (var j = 0; j < geom.length; j += 2) {
        gLat[g] = geom[j];
        gLon[g] = geom[j + 1];
        g++;
      }
    }
    gStart[specs.length] = g;
    return WalkGraph._(
      header: WalkHeader(
        format: walkGraphFormat,
        osmTime: osmTime,
        minLat: bbox[0],
        minLon: bbox[1],
        maxLat: bbox[2],
        maxLon: bbox[3],
        payloadLength: 0,
        payloadSha256: const [],
      ),
      nodeLat: Int32List.fromList([for (final i in order) nodeLat[i]]),
      nodeLon: Int32List.fromList([for (final i in order) nodeLon[i]]),
      edgeA: Int32List.fromList([for (final s in specs) s.a]),
      edgeB: Int32List.fromList([for (final s in specs) s.b]),
      edgeFlags: Uint8List.fromList([for (final s in specs) s.flags]),
      edgeName: edgeName,
      geomStart: gStart,
      geomLat: gLat,
      geomLon: gLon,
      names: names,
    );
  }

  // -- codec -----------------------------------------------------------------

  /// Serialises the graph: header (with the payload hash) + payload.
  Uint8List encode() {
    final w = _Writer();
    w.varint(names.length);
    for (final n in names) {
      final bytes = utf8.encode(n);
      w.varint(bytes.length);
      w.bytes(bytes);
    }
    w.varint(nodeCount);
    var pLat = 0, pLon = 0;
    for (var i = 0; i < nodeCount; i++) {
      w.varint(nodeLat[i] - pLat);
      w.varint(_zig(nodeLon[i] - pLon));
      pLat = nodeLat[i];
      pLon = nodeLon[i];
    }
    w.varint(edgeCount);
    var pa = 0;
    for (var e = 0; e < edgeCount; e++) {
      w.varint(edgeA[e] - pa);
      pa = edgeA[e];
      w.varint(_zig(edgeB[e] - edgeA[e]));
      w.byte(edgeFlags[e]);
      w.varint(edgeName[e] + 1);
      final g0 = geomStart[e], g1 = geomStart[e + 1];
      w.varint(g1 - g0);
      var la = nodeLat[edgeA[e]], lo = nodeLon[edgeA[e]];
      for (var i = g0; i < g1; i++) {
        w.varint(_zig(geomLat[i] - la));
        w.varint(_zig(geomLon[i] - lo));
        la = geomLat[i];
        lo = geomLon[i];
      }
    }
    final payload = w.takeBytes();
    final digest = sha256.convert(payload).bytes;
    final out = BytesBuilder();
    final head = ByteData(walkHeaderBytes);
    for (var i = 0; i < 4; i++) {
      head.setUint8(i, _magic[i]);
    }
    head.setUint16(4, walkGraphFormat, Endian.little);
    head.setInt64(8, header.osmTime, Endian.little);
    head.setInt32(16, header.minLat, Endian.little);
    head.setInt32(20, header.minLon, Endian.little);
    head.setInt32(24, header.maxLat, Endian.little);
    head.setInt32(28, header.maxLon, Endian.little);
    head.setUint32(32, payload.length, Endian.little);
    for (var i = 0; i < 32; i++) {
      head.setUint8(36 + i, digest[i]);
    }
    out.add(head.buffer.asUint8List());
    out.add(payload);
    return out.takeBytes();
  }

  /// Parses and verifies a whole file. Throws [WalkFormatException] on a bad
  /// magic, an unknown format (`incompatible`), a wrong length or hash.
  static WalkGraph decode(Uint8List file) {
    final head = WalkHeader.parse(file);
    if (file.length != walkHeaderBytes + head.payloadLength) {
      throw WalkFormatException('payload length mismatch');
    }
    final payload = Uint8List.sublistView(file, walkHeaderBytes);
    final digest = sha256.convert(payload).bytes;
    for (var i = 0; i < 32; i++) {
      if (digest[i] != head.payloadSha256[i]) {
        throw WalkFormatException('payload hash mismatch');
      }
    }
    try {
      final r = _Reader(payload);
      final names = <String>[];
      final nNames = r.varint();
      for (var i = 0; i < nNames; i++) {
        final len = r.varint();
        names.add(utf8.decode(r.take(len)));
      }
      final nNodes = r.varint();
      final lat = Int32List(nNodes), lon = Int32List(nNodes);
      var pLat = 0, pLon = 0;
      for (var i = 0; i < nNodes; i++) {
        pLat += r.varint();
        pLon += _unzig(r.varint());
        lat[i] = pLat;
        lon[i] = pLon;
      }
      final nEdges = r.varint();
      final ea = Int32List(nEdges), eb = Int32List(nEdges);
      final flags = Uint8List(nEdges);
      final nameIx = Int32List(nEdges);
      final gStart = Int32List(nEdges + 1);
      var gLat = Int32List(nEdges * 2), gLon = Int32List(nEdges * 2);
      var g = 0;
      var pa = 0;
      for (var e = 0; e < nEdges; e++) {
        pa += r.varint();
        ea[e] = pa;
        eb[e] = pa + _unzig(r.varint());
        if (ea[e] >= nNodes || eb[e] < 0 || eb[e] >= nNodes) {
          throw WalkFormatException('edge node out of range');
        }
        flags[e] = r.byte();
        nameIx[e] = r.varint() - 1;
        final n = r.varint();
        gStart[e] = g;
        if (g + n > gLat.length) {
          final cap = math.max(gLat.length * 2, g + n);
          gLat = Int32List(cap)..setRange(0, g, gLat);
          gLon = Int32List(cap)..setRange(0, g, gLon);
        }
        var la = lat[ea[e]], lo = lon[ea[e]];
        for (var i = 0; i < n; i++) {
          la += _unzig(r.varint());
          lo += _unzig(r.varint());
          gLat[g] = la;
          gLon[g] = lo;
          g++;
        }
      }
      gStart[nEdges] = g;
      if (!r.done) throw WalkFormatException('trailing bytes');
      return WalkGraph._(
        header: head,
        nodeLat: lat,
        nodeLon: lon,
        edgeA: ea,
        edgeB: eb,
        edgeFlags: flags,
        edgeName: nameIx,
        geomStart: gStart,
        geomLat: Int32List.sublistView(gLat, 0, g),
        geomLon: Int32List.sublistView(gLon, 0, g),
        names: names,
      );
    } on RangeError {
      throw WalkFormatException('truncated payload');
    }
  }
}

/// Metres between two points in 1e-5 degree units (equirectangular; the
/// graph spans ~20 km, so the error is far under a metre per segment).
double segMetres(int lat1, int lon1, int lat2, int lon2) {
  final dy = (lat2 - lat1) / walkCoordScale * _metresPerDegree;
  final midLat = (lat1 + lat2) / 2 / walkCoordScale * math.pi / 180;
  final dx = (lon2 - lon1) / walkCoordScale * _metresPerDegree * math.cos(midLat);
  return math.sqrt(dx * dx + dy * dy);
}

int _zig(int v) => (v << 1) ^ (v >> 63);
int _unzig(int v) => (v >> 1) ^ -(v & 1);

class _Writer {
  final _b = BytesBuilder(copy: false);
  void byte(int v) => _b.addByte(v);
  void bytes(List<int> v) => _b.add(v);
  void varint(int v) {
    assert(v >= 0);
    while (v >= 0x80) {
      _b.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _b.addByte(v);
  }

  Uint8List takeBytes() => _b.takeBytes();
}

class _Reader {
  _Reader(this.d);
  final Uint8List d;
  int p = 0;
  bool get done => p == d.length;
  int byte() => d[p++];
  Uint8List take(int n) {
    final s = Uint8List.sublistView(d, p, p + n);
    p += n;
    return s;
  }

  int varint() {
    var shift = 0, v = 0;
    while (true) {
      final b = d[p++];
      v |= (b & 0x7f) << shift;
      if (b < 0x80) return v;
      shift += 7;
      if (shift > 63) throw WalkFormatException('bad varint');
    }
  }
}
