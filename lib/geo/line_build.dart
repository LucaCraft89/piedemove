/// Wiring for the line build: OSM tiles -> graphs, GTFS shapes -> corridors,
/// patterns -> snapped geometry. Shared by `tool/build_lines.dart` and
/// `tool/lines_report.dart`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/csv.dart';
import '../data/gtfs_zip.dart';
import '../data/transit_index.dart';
import 'distance.dart';
import 'lines_io.dart';
import 'osm_fetch.dart';
import 'pattern_snap.dart';
import 'road_graph.dart';

typedef BuildLog = void Function(String message);

/// Modal `shape_id` of each pattern's trips; null where the trips carry none.
Future<List<String?>> patternShapeIds(GtfsZip zip, TransitIndex ix) async {
  final votes = <int, Map<String, int>>{};
  final tripIndex = ix.tripIndexById;
  CsvHeader? h;
  await for (final line in zip.lines('trips.txt')) {
    if (line.isEmpty) continue;
    if (h == null) {
      h = CsvHeader(line);
      continue;
    }
    final r = parseCsvLine(line);
    final shape = h.value(r, 'shape_id');
    final trip = tripIndex[h.value(r, 'trip_id') ?? ''];
    if (shape == null || trip == null) continue;
    final p = ix.tripPattern[trip];
    (votes[p] ??= <String, int>{}).update(shape, (v) => v + 1, ifAbsent: () => 1);
  }
  return [
    for (var p = 0; p < ix.patternCount; p++)
      votes[p] == null
          ? null
          : (votes[p]!.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .first
              .key
  ];
}

/// Reads the listed shapes into polylines. Shapes not in [needed] are skipped.
Future<Map<String, ShapePolyline>> readShapes(
    GtfsZip zip, Set<String> needed) async {
  final lat = <String, List<double>>{};
  final lon = <String, List<double>>{};
  final seq = <String, List<int>>{};
  CsvHeader? h;
  await for (final line in zip.lines('shapes.txt')) {
    if (line.isEmpty) continue;
    if (h == null) {
      h = CsvHeader(line);
      continue;
    }
    final r = parseCsvLine(line);
    final id = h.value(r, 'shape_id');
    if (id == null || !needed.contains(id)) continue;
    final y = double.tryParse(h.value(r, 'shape_pt_lat') ?? '');
    final x = double.tryParse(h.value(r, 'shape_pt_lon') ?? '');
    if (y == null || x == null) continue;
    (lat[id] ??= <double>[]).add(y);
    (lon[id] ??= <double>[]).add(x);
    (seq[id] ??= <int>[])
        .add(int.tryParse(h.value(r, 'shape_pt_sequence') ?? '') ?? 0);
  }
  final out = <String, ShapePolyline>{};
  for (final id in lat.keys) {
    final order = [for (var i = 0; i < seq[id]!.length; i++) i]
      ..sort((a, b) => seq[id]![a].compareTo(seq[id]![b]));
    if (order.length < 2) continue;
    out[id] = ShapePolyline(
      Float64List.fromList([for (final i in order) lat[id]![i]]),
      Float64List.fromList([for (final i in order) lon[id]![i]]),
    );
  }
  return out;
}

const corridorCellDegrees = 0.002; // ~220 m
const corridorPadCells = 2;

/// Cells within roughly 400 m of a bus or tram pattern's stop-to-stop chords.
/// Ways outside this corridor are never useful for snapping and would triple
/// the graph: the GTT area is mostly countryside.
Set<int> corridorCells(TransitIndex ix) {
  final cells = <int>{};
  void mark(double lat, double lon) {
    final y = (lat / corridorCellDegrees).floor();
    final x = (lon / corridorCellDegrees).floor();
    for (var dy = -corridorPadCells; dy <= corridorPadCells; dy++) {
      for (var dx = -corridorPadCells; dx <= corridorPadCells; dx++) {
        cells.add((y + dy) * 1000000 + x + dx);
      }
    }
  }

  for (var p = 0; p < ix.patternCount; p++) {
    final type = ix.routeTypeOfPattern(p);
    if (type != RouteType.bus && type != RouteType.tram) continue;
    for (var i = 0; i + 1 < ix.patternLength(p); i++) {
      final a = ix.patternStopAt(p, i), b = ix.patternStopAt(p, i + 1);
      final steps = 1 +
          (haversineMetres(ix.stopLat[a], ix.stopLon[a], ix.stopLat[b],
                      ix.stopLon[b]) /
                  100)
              .ceil();
      for (var k = 0; k <= steps; k++) {
        final t = k / steps;
        mark(ix.stopLat[a] + (ix.stopLat[b] - ix.stopLat[a]) * t,
            ix.stopLon[a] + (ix.stopLon[b] - ix.stopLon[a]) * t);
      }
    }
  }
  return cells;
}

bool _touchesCorridor(OsmWay w, Set<int> cells) {
  for (var i = 0; i < w.lat.length; i++) {
    final key = (w.lat[i] / corridorCellDegrees).floor() * 1000000 +
        (w.lon[i] / corridorCellDegrees).floor();
    if (cells.contains(key)) return true;
  }
  return false;
}

/// Parses the cached Overpass tiles into one graph per mode.
Map<GraphMode, RoadGraph> buildGraphs(List<File> tiles,
    {Set<int>? corridor, BuildLog? log}) {
  final builders = {
    GraphMode.bus: RoadGraphBuilder(GraphMode.bus),
    GraphMode.tram: RoadGraphBuilder(GraphMode.tram),
  };
  for (final file in tiles) {
    var ways = parseOsmJson(utf8.decode(gzip.decode(file.readAsBytesSync())));
    if (corridor != null) {
      ways = [for (final w in ways) if (_touchesCorridor(w, corridor)) w];
    }
    for (final b in builders.values) {
      b.addAll(ways);
    }
    log?.call('${file.uri.pathSegments.last}: ${ways.length} ways');
  }
  return {for (final e in builders.entries) e.key: e.value.build()};
}

/// Tiles covering the stops of bus and tram patterns only — the modes that
/// are snapped. Tiles with no such stop are never fetched: the GTT stop bbox
/// spans most of the province and is mostly empty countryside.
List<OsmTile> tilesForIndex(TransitIndex ix) {
  final wanted = <int>{};
  for (var p = 0; p < ix.patternCount; p++) {
    final type = ix.routeTypeOfPattern(p);
    if (type != RouteType.bus && type != RouteType.tram) continue;
    for (var i = 0; i < ix.patternLength(p); i++) {
      final s = ix.patternStopAt(p, i);
      final y = (ix.stopLat[s] / osmTileDegrees).floor();
      final x = (ix.stopLon[s] / osmTileDegrees).floor();
      wanted.add(y * 100000 + x + 50000);
    }
  }
  return [
    for (final key in wanted)
      OsmTile(
        (key ~/ 100000) * osmTileDegrees,
        (key % 100000 - 50000) * osmTileDegrees,
        (key ~/ 100000 + 1) * osmTileDegrees,
        (key % 100000 - 50000 + 1) * osmTileDegrees,
      ),
  ]..sort((a, b) => a.name.compareTo(b.name));
}

/// Geometry for a pattern that is not snapped (metro, funicular, or no graph):
/// the GTFS shape as published, or the stop chain when there is none.
SnappedPattern shapeChainPattern(
    int pattern, Float64List stopLat, Float64List stopLon,
    {ShapePolyline? shape}) {
  if (shape == null) {
    final n = stopLat.length;
    return SnappedPattern(
      pattern: pattern,
      vertexLat: Int32List.fromList([for (final v in stopLat) microdeg(v)]),
      vertexLon: Int32List.fromList([for (final v in stopLon) microdeg(v)]),
      vertexWay: Int64List(n)..fillRange(0, n, -1),
      vertexDir: Uint8List(n),
      stopVertex: Int32List.fromList([for (var i = 0; i < n; i++) i]),
      stopLat: Int32List.fromList([for (final v in stopLat) microdeg(v)]),
      stopLon: Int32List.fromList([for (final v in stopLon) microdeg(v)]),
      hopApprox: Uint8List(n > 0 ? n - 1 : 0),
    );
  }
  // Walk the shape forward once, so a stop visited twice on a loop lands on
  // the right pass (never a global nearest-vertex search).
  final n = stopLat.length;
  final stopVertex = Int32List(n);
  var cursor = 0;
  for (var s = 0; s < n; s++) {
    var best = cursor, bestD = double.infinity;
    for (var v = cursor; v < shape.lat.length; v++) {
      final d = haversineSquaredish(shape.lat[v], shape.lon[v], stopLat[s], stopLon[s]);
      if (d < bestD) {
        bestD = d;
        best = v;
      }
    }
    stopVertex[s] = best;
    cursor = best;
  }
  return SnappedPattern(
    pattern: pattern,
    vertexLat: Int32List.fromList([for (final v in shape.lat) microdeg(v)]),
    vertexLon: Int32List.fromList([for (final v in shape.lon) microdeg(v)]),
    vertexWay: Int64List(shape.lat.length)..fillRange(0, shape.lat.length, -1),
    vertexDir: Uint8List(shape.lat.length),
    stopVertex: stopVertex,
    stopLat: Int32List.fromList([for (final v in stopLat) microdeg(v)]),
    stopLon: Int32List.fromList([for (final v in stopLon) microdeg(v)]),
    hopApprox: Uint8List(n > 0 ? n - 1 : 0),
  );
}

/// Cheap squared planar distance: only ever compared against itself.
double haversineSquaredish(double aLat, double aLon, double bLat, double bLon) {
  final dy = aLat - bLat;
  final dx = (aLon - bLon) * 0.7;
  return dy * dy + dx * dx;
}

/// Snaps every bus and tram pattern; metro and funicular keep their shape.
LineNetwork buildLineNetwork({
  required TransitIndex ix,
  required Map<GraphMode, RoadGraph> graphs,
  required List<String?> shapeIds,
  required Map<String, ShapePolyline> shapes,
  bool osmApproximate = false,
  BuildLog? log,
}) {
  final snappers = {
    for (final e in graphs.entries) e.key: PatternSnapper(e.value),
  };
  final out = <SnappedPattern>[];
  for (var p = 0; p < ix.patternCount; p++) {
    final type = ix.routeTypeOfPattern(p);
    final len = ix.patternLength(p);
    if (len < 2) continue;
    final stopLat = Float64List(len), stopLon = Float64List(len);
    for (var i = 0; i < len; i++) {
      final s = ix.patternStopAt(p, i);
      stopLat[i] = ix.stopLat[s];
      stopLon[i] = ix.stopLon[s];
    }
    final shape = shapeIds[p] == null ? null : shapes[shapeIds[p]];
    final mode = switch (type) {
      RouteType.tram => GraphMode.tram,
      RouteType.bus => GraphMode.bus,
      _ => null,
    };
    final snapper = mode == null ? null : snappers[mode];
    out.add(snapper == null
        ? shapeChainPattern(p, stopLat, stopLon, shape: shape)
        : snapper.snap(
            pattern: p, stopLat: stopLat, stopLon: stopLon, shape: shape));
    if (log != null && (p & 127) == 0) {
      log('pattern $p/${ix.patternCount}');
    }
  }
  for (final e in snappers.entries) {
    log?.call('${e.key == GraphMode.bus ? 'bus' : 'tram'} chords: '
        'unsnapped stop ${e.value.chordUnsnappedStop}, '
        'no route ${e.value.chordNoRoute}, '
        'off shape ${e.value.chordOffShape}; exhausted ${e.value.failExhausted} '
        '(avg ${e.value.failExhausted == 0 ? 0 : e.value.failSettled ~/ e.value.failExhausted} edges), '
        'over cap ${e.value.failCap}; deviation <100/<200/<500/500+ '
        '${e.value.deviationBuckets.join("/")}');
  }
  return LineNetwork(ix.feedVersion, out, osmApproximate: osmApproximate);
}
