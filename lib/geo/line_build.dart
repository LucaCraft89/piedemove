/// Wiring for the line build: OSM tiles -> graphs, GTFS shapes -> corridors,
/// patterns -> snapped geometry. Shared by `tool/build_lines.dart` and
/// `tool/lines_report.dart`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../data/csv.dart';
import '../data/gtfs_zip.dart';
import '../data/transit_index.dart';
import 'distance.dart';
import 'lines_io.dart';
import 'osm_fetch.dart';
import 'map_match.dart';
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
const corridorPadCells = 1;

/// Cells within about one cell (~200 m) of a bus or tram pattern's GTFS shape
/// (its stop chain where it has none). Ways outside this corridor are never
/// useful for matching and would triple the graph: the GTT area is mostly
/// countryside.
Set<int> corridorCells(TransitIndex ix, List<String?> shapeIds,
    Map<String, ShapePolyline> shapes) {
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

  void chain(double aLat, double aLon, double bLat, double bLon) {
    final steps = 1 + (haversineMetres(aLat, aLon, bLat, bLon) / 100).ceil();
    for (var k = 0; k <= steps; k++) {
      final t = k / steps;
      mark(aLat + (bLat - aLat) * t, aLon + (bLon - aLon) * t);
    }
  }

  final done = <String>{};
  for (var p = 0; p < ix.patternCount; p++) {
    if (!isMatchedPattern(ix, p)) continue;
    final shape = shapeIds[p] == null ? null : shapes[shapeIds[p]];
    if (shape != null) {
      if (!done.add(shapeIds[p]!)) continue;
      for (var i = 0; i + 1 < shape.lat.length; i++) {
        chain(shape.lat[i], shape.lon[i], shape.lat[i + 1], shape.lon[i + 1]);
      }
      continue;
    }
    for (var i = 0; i + 1 < ix.patternLength(p); i++) {
      final a = ix.patternStopAt(p, i), b = ix.patternStopAt(p, i + 1);
      chain(ix.stopLat[a], ix.stopLon[a], ix.stopLat[b], ix.stopLon[b]);
    }
  }
  return cells;
}

/// Bus and tram patterns of the GTT feed: the ones matched to roads. Regional
/// (scheduled-only) buses have no shapes and are not drawn on the map.
bool isMatchedPattern(TransitIndex ix, int p) {
  final type = ix.routeTypeOfPattern(p);
  return (type == RouteType.bus || type == RouteType.tram) &&
      !ix.patternScheduledOnly(p);
}

bool _touchesCorridor(OsmWay w, Set<int> cells) {
  for (var i = 0; i < w.lat.length; i++) {
    final key = (w.lat[i] / corridorCellDegrees).floor() * 1000000 +
        (w.lon[i] / corridorCellDegrees).floor();
    if (cells.contains(key)) return true;
  }
  return false;
}

/// Parses the cached Overpass tiles into one graph per mode. [railFile] holds
/// the metro and funicular tracks (their own graph).
Map<GraphMode, RoadGraph> buildGraphs(List<File> tiles,
    {Set<int>? corridor, File? railFile, BuildLog? log}) {
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
  final graphs = {for (final e in builders.entries) e.key: e.value.build()};
  if (railFile != null) {
    final ways = parseOsmJson(utf8.decode(gzip.decode(railFile.readAsBytesSync())));
    graphs[GraphMode.rail] = (RoadGraphBuilder(GraphMode.rail)..addAll(ways)).build();
  }
  return graphs;
}

/// Bounding box (s, w, n, e), padded, of the stops of metro and funicular
/// patterns; null when the feed has none.
(double, double, double, double)? railBounds(TransitIndex ix, {double pad = 0.01}) {
  double? s, w, n, e;
  for (var p = 0; p < ix.patternCount; p++) {
    if (!isRailPattern(ix, p)) continue;
    for (var i = 0; i < ix.patternLength(p); i++) {
      final st = ix.patternStopAt(p, i);
      final la = ix.stopLat[st], lo = ix.stopLon[st];
      s = s == null ? la : math.min(s, la);
      n = n == null ? la : math.max(n, la);
      w = w == null ? lo : math.min(w, lo);
      e = e == null ? lo : math.max(e, lo);
    }
  }
  return s == null ? null : (s - pad, w! - pad, n! + pad, e! + pad);
}

/// Metro and funicular patterns of the GTT feed.
bool isRailPattern(TransitIndex ix, int p) {
  final type = ix.routeTypeOfPattern(p);
  return (type == RouteType.metro || type == RouteType.funicular) &&
      !ix.patternScheduledOnly(p);
}

/// Tiles covering the stops and shapes of the matched patterns. Tiles with
/// neither are never fetched: the GTT stop bbox spans most of the province and
/// is mostly empty countryside.
List<OsmTile> tilesForIndex(TransitIndex ix,
    {List<String?>? shapeIds, Map<String, ShapePolyline>? shapes}) {
  final wanted = <int>{};
  void want(double lat, double lon) {
    final y = (lat / osmTileDegrees).floor();
    final x = (lon / osmTileDegrees).floor();
    wanted.add(y * 100000 + x + 50000);
  }

  final doneShapes = <String>{};
  for (var p = 0; p < ix.patternCount; p++) {
    if (!isMatchedPattern(ix, p)) continue;
    for (var i = 0; i < ix.patternLength(p); i++) {
      final s = ix.patternStopAt(p, i);
      want(ix.stopLat[s], ix.stopLon[s]);
    }
    final id = shapeIds?[p];
    final shape = id == null ? null : shapes?[id];
    if (shape != null && doneShapes.add(id!)) {
      for (var i = 0; i < shape.lat.length; i++) {
        want(shape.lat[i], shape.lon[i]);
      }
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

/// Matches every GTT bus and tram pattern on its graph; metro and funicular
/// keep their shape; regional (scheduled-only) patterns are left out.
LineNetwork buildLineNetwork({
  required TransitIndex ix,
  required Map<GraphMode, RoadGraph> graphs,
  required List<String?> shapeIds,
  required Map<String, ShapePolyline> shapes,
  bool osmApproximate = false,
  BuildLog? log,
  Map<GraphMode, MatchStats>? statsOut,
}) {
  final snappers = {
    for (final e in graphs.entries) e.key: PatternSnapper(e.value),
  };
  final out = <SnappedPattern>[];
  for (var p = 0; p < ix.patternCount; p++) {
    final type = ix.routeTypeOfPattern(p);
    final len = ix.patternLength(p);
    if (len < 2 || ix.patternScheduledOnly(p)) continue;
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
      _ => GraphMode.rail,
    };
    final rail = mode == GraphMode.rail;
    final snapper = snappers[mode];
    // Own rails with a shape: the shape as published is the track. Otherwise
    // road and tram patterns are matched, and a metro without a shape is routed
    // stop to stop over the rail graph. No graph: the guess is marked.
    if (rail && shape != null) {
      out.add(snapShapeOnly(p, stopLat, stopLon, shape));
    } else if (snapper == null) {
      out.add(snapShapeOnly(p, stopLat, stopLon, shape, approximate: true));
    } else {
      out.add(snapper.snap(
          pattern: p, stopLat: stopLat, stopLon: stopLon, shape: shape));
    }
    if (log != null && (p & 127) == 0) log('pattern $p/${ix.patternCount}');
  }
  statsOut?.addAll({for (final e in snappers.entries) e.key: e.value.stats});
  return LineNetwork(ix.feedVersion, out, osmApproximate: osmApproximate);
}
