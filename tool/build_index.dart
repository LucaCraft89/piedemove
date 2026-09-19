/// GTFS ingest: download (or reuse) the GTT feed, build the index, write
/// `build/index.bin`.
///
///     dart tool/build_index.dart [--force] [--zip path]
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:piedemove/data/feeds.dart';
import 'package:piedemove/data/gtfs_zip.dart';
import 'package:piedemove/data/index_build.dart';
import 'package:piedemove/data/index_io.dart';

const indexPath = 'build/index.bin';
const zipPath = 'build/gtt_gtfs.zip';

Future<void> main(List<String> args) async {
  final force = args.contains('--force');
  final zipArg = args.indexOf('--zip');
  final zip = zipArg >= 0 ? args[zipArg + 1] : zipPath;

  Directory('build').createSync(recursive: true);
  final zipFile = File(zip);
  if (force || !zipFile.existsSync()) {
    stdout.writeln('downloading ${Feeds.gttStaticGtfs} ...');
    final response = await http.get(Uri.parse(Feeds.gttStaticGtfs));
    if (response.statusCode != 200) {
      stderr.writeln('download failed: HTTP ${response.statusCode}');
      exit(1);
    }
    await zipFile.writeAsBytes(response.bodyBytes, flush: true);
  }
  stdout.writeln('zip ${(zipFile.lengthSync() / 1e6).toStringAsFixed(1)} MB');

  final started = DateTime.now();
  final source = GtfsZip(zipFile.path, Directory('build'));
  var lastStage = '';
  final index = await buildIndex(source, onProgress: (stage, f) {
    if (stage != lastStage) {
      lastStage = stage;
      stdout.writeln('  $stage ...');
    }
  });
  source.close();

  await writeIndexFile(index, indexPath);
  final size = File(indexPath).lengthSync();
  stdout.writeln('''
feed_version ${index.feedVersion}
stops        ${index.stopCount}
routes       ${index.routeCount}
patterns     ${index.patternCount}
trips        ${index.tripCount}
services     ${index.serviceCount} over ${index.serviceDayCount} days
index        ${(size / 1e6).toStringAsFixed(1)} MB -> $indexPath
built in     ${DateTime.now().difference(started).inSeconds}s''');
}
