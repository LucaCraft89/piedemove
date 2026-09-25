/// Line geometry build: GTFS shapes + Overpass roads -> matched patterns ->
/// `build/lines.bin` and the phone assets.
///
///     dart tool/build_lines.dart [--force-osm] [--reverse] [--no-assets]
///                                [--opl roads.opl] [--zip gtt.zip]
///
/// With `--opl` the roads come from an osmium OPL dump with node locations
/// (`osmium add-locations-to-ways` + `osmium cat -f opl`, as the `lines` CI
/// workflow makes from the Geofabrik extract) instead of Overpass tiles.
///
/// Regenerates every shipped line asset from the GTFS zip and the OSM tile
/// cache (fetching what is missing or older than 30 days). Nothing here is
/// keyed to a line, a stop or a coordinate: re-run it when GTT or the Turin
/// roads change.
library;

import 'dart:convert';
import 'dart:io';

import 'package:piedemove/data/gtfs_zip.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/ambient.dart';
import 'package:piedemove/geo/line_build.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/map_match.dart';
import 'package:piedemove/geo/osm_fetch.dart';
import 'package:piedemove/geo/osm_opl.dart';
import 'package:piedemove/geo/road_graph.dart';

const indexPath = 'build/index.bin';
const linesPath = 'build/lines.bin';

Future<void> main(List<String> args) async {
  final started = DateTime.now();
  final zipArg = args.indexOf('--zip');
  final zipPath =
      zipArg >= 0 && zipArg + 1 < args.length ? args[zipArg + 1] : 'build/gtt_gtfs.zip';

  final ix = await readIndexFile(indexPath);
  if (ix == null) {
    stderr.writeln('no usable $indexPath - run tool/build_index.dart first');
    exit(1);
  }
  stdout.writeln('index ${ix.patternCount} patterns, feed ${ix.feedVersion}');

  // GTFS shapes first: they decide which OSM tiles and ways are needed.
  final zip = GtfsZip(zipPath, Directory('build'));
  final shapeIds = await patternShapeIds(zip, ix);
  final shapes = await readShapes(zip, shapeIds.whereType<String>().toSet());
  zip.close();
  stdout.writeln('shapes ${shapes.length}');

  // OSM input: an osmium OPL dump (CI, from a Geofabrik extract) or Overpass
  // tiles (desktop). Both end as the same `out geom` JSON the graph reads.
  final oplArg = args.indexOf('--opl');
  final List<File> files;
  final File? railFile;
  if (oplArg >= 0 && oplArg + 1 < args.length) {
    final opl = File(args[oplArg + 1]).readAsLinesSync();
    stdout.writeln('opl: ${opl.length} lines from ${args[oplArg + 1]}');
    Directory('build/osm').createSync(recursive: true);
    File dump(String name, bool Function(Map<String, String>) keep) =>
        File('build/osm/$name.json.gz')
          ..writeAsBytesSync(gzip.encode(
              utf8.encode(jsonEncode(oplWaysToOverpassGeom(opl, keep)))));
    files = [dump('opl_roads', isRoadOrTramWay)];
    railFile = railBounds(ix) == null ? null : dump('opl_rail', isRailWay);
  } else {
    // Two fetchers (Overpass allows two slots per IP) halve the wall time: run
    // a second process with --reverse, it skips whatever the first has cached.
    final tiles = tilesForIndex(ix, shapeIds: shapeIds, shapes: shapes);
    if (args.contains('--reverse')) tiles.setAll(0, tiles.reversed.toList());
    stdout.writeln('overpass: ${tiles.length} tiles');
    files = await fetchOsmTiles(
      tiles,
      cacheDir: Directory('build/osm'),
      force: args.contains('--force-osm'),
      log: (m) => stdout.writeln('  $m'),
    );
    stdout.writeln('tiles usable ${files.length}/${tiles.length}');

    final rb = railBounds(ix);
    railFile = rb == null
        ? null
        : await fetchRailWays(rb.$1, rb.$2, rb.$3, rb.$4,
            cacheDir: Directory('build/osm'),
            force: args.contains('--force-osm'),
            log: (m) => stdout.writeln('  $m'));
  }
  final Map<GraphMode, RoadGraph> graphs = buildGraphs(files,
          corridor: corridorCells(ix, shapeIds, shapes),
          railFile: railFile,
          log: (m) => stdout.writeln('  $m'));
  graphs.removeWhere((_, g) => g.nodeCount == 0); // none fetched: shape/chain fallback
  for (final e in graphs.entries) {
    stdout.writeln('${e.key.name} graph: ${e.value.nodeCount} nodes, '
        '${e.value.edgeCount} directed edges');
  }

  final matchStarted = DateTime.now();
  final stats = <GraphMode, MatchStats>{};
  final net = buildLineNetwork(
    ix: ix,
    graphs: graphs,
    shapeIds: shapeIds,
    shapes: shapes,
    osmApproximate: graphs.isEmpty,
    statsOut: stats,
  );
  await writeLinesFile(net, linesPath);
  for (final e in stats.entries) {
    final s = e.value;
    stdout.writeln('${e.key.name}: ${s.patterns} patterns, ${s.samples} samples '
        '(${s.unmatchedSamples} without candidates, ${s.wideRetries} widened), '
        '${s.runs} runs, ${s.bridged} bridged, ${s.approxGaps} dotted gaps '
        '(${s.approxMetres.round()} m), ${s.spursRemoved} spurs removed; '
        'causes ${s.gapCause}');
  }
  File('build/gaps.txt').writeAsStringSync([
    for (final e in stats.entries) ...e.value.gaps.map((g) => '${e.key.name} $g'),
  ].join('\n'));
  stdout.writeln('matched in ${DateTime.now().difference(matchStarted).inSeconds}s');

  if (!args.contains('--no-assets')) await writeAssets(ix, net, graphs);

  stdout.writeln('lines.bin  ${(File(linesPath).lengthSync() / 1e6).toStringAsFixed(1)} MB\n'
      'built in   ${DateTime.now().difference(started).inSeconds}s');
}

/// Ships the phone's line assets: the matched patterns (focus mode needs
/// per-pattern geometry), the pre-merged ambient network (§9.4) and the stop
/// connectors (§9.7).
Future<void> writeAssets(
    TransitIndex ix, LineNetwork net, Map<GraphMode, RoadGraph> graphs) async {
  Directory('assets').createSync(recursive: true);
  final lines = File('assets/lines.bin.gz');
  lines.writeAsBytesSync(gzip.encode(File(linesPath).readAsBytesSync()));
  final ambient = File('assets/ambient.json.gz');
  ambient.writeAsBytesSync(gzip.encode(utf8.encode(ambientGeoJson(ix, net, graphs))));
  final connectors = File('assets/connectors.json.gz');
  connectors.writeAsBytesSync(gzip.encode(utf8.encode(connectorsGeoJson(ix, net))));
  String mb(File f) => (f.lengthSync() / 1e6).toStringAsFixed(2);
  stdout.writeln('assets     lines.bin.gz ${mb(lines)} MB, ambient.json.gz '
      '${mb(ambient)} MB, connectors.json.gz ${mb(connectors)} MB');
}
