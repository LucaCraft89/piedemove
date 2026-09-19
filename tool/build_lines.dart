/// Line geometry build: Overpass fetch -> directed graphs -> snapped patterns
/// -> `build/lines.bin`.
///
///     dart tool/build_lines.dart [--force-osm] [--reverse] [--zip path]
library;

import 'dart:io';

import 'package:piedemove/data/gtfs_zip.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/geo/line_build.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/osm_fetch.dart';
import 'package:piedemove/geo/road_graph.dart';

const indexPath = 'build/index.bin';
const linesPath = 'build/lines.bin';

Future<void> main(List<String> args) async {
  final zipArg = args.indexOf('--zip');
  final zipPath = zipArg >= 0 ? args[zipArg + 1] : 'build/gtt_gtfs.zip';

  final ix = await readIndexFile(indexPath);
  if (ix == null) {
    stderr.writeln('no usable $indexPath - run tool/build_index.dart first');
    exit(1);
  }
  stdout.writeln('index ${ix.patternCount} patterns, feed ${ix.feedVersion}');

  // Two fetchers (Overpass allows two slots per IP) halve the wall time: run
  // a second process with --reverse, it skips whatever the first has cached.
  final tiles = tilesForIndex(ix);
  if (args.contains('--reverse')) tiles.setAll(0, tiles.reversed.toList());
  stdout.writeln('overpass: ${tiles.length} tiles');
  final files = await fetchOsmTiles(
    tiles,
    cacheDir: Directory('build/osm'),
    force: args.contains('--force-osm'),
    log: (m) => stdout.writeln('  $m'),
  );
  stdout.writeln('tiles usable ${files.length}/${tiles.length}');

  final Map<GraphMode, RoadGraph> graphs = files.isEmpty
      ? const {}
      : buildGraphs(files,
          corridor: args.contains('--no-corridor') ? null : corridorCells(ix),
          log: (m) => stdout.writeln('  $m'));
  for (final e in graphs.entries) {
    stdout.writeln('${e.key.name} graph: ${e.value.nodeCount} nodes, '
        '${e.value.edgeCount} directed edges');
  }

  final zip = GtfsZip(zipPath, Directory('build'));
  final shapeIds = await patternShapeIds(zip, ix);
  final shapes = await readShapes(zip, shapeIds.whereType<String>().toSet());
  zip.close();
  stdout.writeln('shapes ${shapes.length}');

  final started = DateTime.now();
  final net = buildLineNetwork(
    ix: ix,
    graphs: graphs,
    shapeIds: shapeIds,
    shapes: shapes,
    osmApproximate: graphs.isEmpty,
    log: (m) => stdout.writeln('  $m'),
  );
  await writeLinesFile(net, linesPath);

  var hops = 0, chords = 0;
  for (final p in net.patterns) {
    hops += p.hopApprox.length;
    chords += p.approxHops;
  }
  stdout.writeln('''
patterns   ${net.patterns.length}
hops       $hops, chorded $chords (${(100 * chords / (hops == 0 ? 1 : hops)).toStringAsFixed(1)}%)
lines.bin  ${(File(linesPath).lengthSync() / 1e6).toStringAsFixed(1)} MB
built in   ${DateTime.now().difference(started).inSeconds}s''');
}
