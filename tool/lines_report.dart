/// 9.12 — line snapping validation. The phase 6 gate.
///
///     dart tool/lines_report.dart [--full]
///
/// Prints, per line and overall: patterns fully snapped, hops chorded, hops
/// off their GTFS shape, segments that violate a oneway, and vertices sitting
/// more than 8 m from any graph edge (chords excluded).
library;

import 'dart:io';

import 'package:piedemove/data/gtfs_zip.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/line_build.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/osm_fetch.dart';
import 'package:piedemove/geo/pattern_snap.dart';
import 'package:piedemove/geo/road_graph.dart';

const offGraphLimitMetres = 8.0;

class _Stats {
  int patterns = 0, snapped = 0, hops = 0, chords = 0;
  int offShape = 0, onewayViolations = 0, offGraph = 0, vertices = 0;

  void add(_Stats o) {
    patterns += o.patterns;
    snapped += o.snapped;
    hops += o.hops;
    chords += o.chords;
    offShape += o.offShape;
    onewayViolations += o.onewayViolations;
    offGraph += o.offGraph;
    vertices += o.vertices;
  }

  String get line => '${patterns.toString().padLeft(4)} pat '
      '${snapped.toString().padLeft(4)} full '
      '${hops.toString().padLeft(6)} hops '
      '${chords.toString().padLeft(5)} chord '
      '${offShape.toString().padLeft(5)} offshape '
      '${onewayViolations.toString().padLeft(4)} oneway '
      '${offGraph.toString().padLeft(6)} offgraph/${vertices}v';
}

Future<void> main(List<String> args) async {
  final ix = await readIndexFile('build/index.bin');
  final net = await readLinesFile('build/lines.bin');
  if (ix == null || net == null) {
    stderr.writeln('need build/index.bin and build/lines.bin');
    exit(1);
  }
  if (net.feedVersion != ix.feedVersion) {
    stderr.writeln('lines.bin is for feed ${net.feedVersion}, '
        'index is ${ix.feedVersion} - rebuild');
    exit(1);
  }

  final graphs = buildGraphs(
      await fetchOsmTiles(tilesForIndex(ix), cacheDir: Directory('build/osm')));
  final nodeOf = <GraphMode, Map<int, int>>{};
  for (final e in graphs.entries) {
    final map = <int, int>{};
    for (var n = 0; n < e.value.nodeCount; n++) {
      map[microdeg(e.value.nodeLat[n]) * 4294967296 + microdeg(e.value.nodeLon[n])] = n;
    }
    nodeOf[e.key] = map;
  }

  final zip = GtfsZip('build/gtt_gtfs.zip', Directory('build'));
  final shapeIds = await patternShapeIds(zip, ix);
  final shapes = await readShapes(zip, shapeIds.whereType<String>().toSet());
  zip.close();

  final perLine = <String, _Stats>{};
  final overall = _Stats();

  for (final p in net.patterns) {
    final type = ix.routeTypeOfPattern(p.pattern);
    if (type != RouteType.bus && type != RouteType.tram) continue;
    final graph = graphs[type == RouteType.tram ? GraphMode.tram : GraphMode.bus]!;
    final nodes = nodeOf[type == RouteType.tram ? GraphMode.tram : GraphMode.bus]!;
    final shape = shapes[shapeIds[p.pattern]];
    final s = _Stats()
      ..patterns = 1
      ..hops = p.hopApprox.length
      ..chords = p.approxHops
      ..vertices = p.vertexCount;
    if (s.chords == 0) s.snapped = 1;

    for (var v = 0; v < p.vertexCount; v++) {
      final lat = p.vertexLat[v] / 1e6, lon = p.vertexLon[v] / 1e6;
      final chordVertex = p.vertexWay[v] < 0;
      if (!chordVertex) {
        if (shape != null && shape.distanceTo(lat, lon) > offShapeLimitMetres) {
          s.offShape++;
        }
        if (graph.near(lat, lon, offGraphLimitMetres).isEmpty) s.offGraph++;
      }
      if (v == 0 || chordVertex) continue;
      final a = nodes[p.vertexLat[v - 1] * 4294967296 + p.vertexLon[v - 1]];
      final b = nodes[p.vertexLat[v] * 4294967296 + p.vertexLon[v]];
      if (a == null || b == null) continue; // snapped stop point, not a node
      final way = p.vertexWay[v];
      var forward = false, reverse = false;
      for (final e in graph.edgesFrom(a)) {
        if (graph.edgeWay[e] == way && graph.edgeTo[e] == b) forward = true;
      }
      for (final e in graph.edgesFrom(b)) {
        if (graph.edgeWay[e] == way && graph.edgeTo[e] == a) reverse = true;
      }
      if (!forward && reverse) s.onewayViolations++;
    }

    final name = ix.routeShortNameOfPattern(p.pattern);
    (perLine[name] ??= _Stats()).add(s);
    overall.add(s);
  }

  final names = perLine.keys.toList()..sort();
  final full = args.contains('--full');
  for (final name in names) {
    final s = perLine[name]!;
    if (!full && s.chords == 0 && s.onewayViolations == 0 && s.offGraph == 0) {
      continue;
    }
    stdout.writeln('${name.padRight(6)} ${s.line}');
  }
  stdout.writeln('${'-' * 72}\nTOTAL  ${overall.line}');
  final chordPct = 100 * overall.chords / (overall.hops == 0 ? 1 : overall.hops);
  stdout.writeln('chorded ${chordPct.toStringAsFixed(2)}% of hops, '
      'lines listed: ${full ? names.length : names.length - names.where((n) {
        final s = perLine[n]!;
        return s.chords == 0 && s.onewayViolations == 0 && s.offGraph == 0;
      }).length}/${names.length}');
}
