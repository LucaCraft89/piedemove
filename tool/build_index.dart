/// GTFS ingest: download (or reuse) the GTT feed, build the index, write
/// `build/index.bin`.
///
///     dart tool/build_index.dart [--force] [--zip path] [--no-regional]
///
/// The Regione Piemonte bus feed (scheduled only) is merged in unless
/// `--no-regional` is passed; its zip is cached next to the GTT one.
library;

import 'dart:io';

import 'package:piedemove/data/download.dart';
import 'package:piedemove/data/feeds.dart';
import 'package:piedemove/data/gtfs_zip.dart';
import 'package:piedemove/data/index_build.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/index_merge.dart';
import 'package:piedemove/data/transit_index.dart';

const indexPath = 'build/index.bin';
const zipPath = 'build/gtt_gtfs.zip';
const regionalZipPath = 'build/piemonte_bus.zip';

Future<File> _download(String url, String path, {bool force = false}) async {
  final file = File(path);
  if (force || !file.existsSync()) {
    stdout.writeln('downloading $url ...');
    try {
      await downloadToFile(url, path, timeout: const Duration(seconds: 60));
    } catch (e) {
      stderr.writeln('download failed: $e');
      exit(1);
    }
  }
  return file;
}

Future<void> main(List<String> args) async {
  final force = args.contains('--force');
  final zipArg = args.indexOf('--zip');
  final zip = zipArg >= 0 && zipArg + 1 < args.length ? args[zipArg + 1] : zipPath;

  Directory('build').createSync(recursive: true);
  final zipFile = await _download(Feeds.gttStaticGtfs, zip, force: force);
  stdout.writeln('zip ${(zipFile.lengthSync() / 1e6).toStringAsFixed(1)} MB');

  final started = DateTime.now();
  final source = GtfsZip(zipFile.path, Directory('build'));
  var lastStage = '';
  var index = await buildIndex(source, onProgress: (stage, f) {
    if (stage != lastStage) {
      lastStage = stage;
      stdout.writeln('  $stage ...');
    }
  });
  source.close();

  var merged = index;
  if (!args.contains('--no-regional')) {
    final regionalZip =
        await _download(Feeds.piemonteBusGtfs, regionalZipPath, force: force);
    stdout.writeln(
        'regional zip ${(regionalZip.lengthSync() / 1e6).toStringAsFixed(1)} MB');
    final regionalSource = GtfsZip(regionalZip.path, Directory('build'));
    final regional = await buildIndex(regionalSource);
    regionalSource.close();
    merged = mergeRegional(index, regional);
    final keptRoutes = [
      for (var r = 0; r < merged.routeCount; r++)
        if (merged.routeFeed[r] == feedRegional) r
    ].length;
    stdout.writeln('regional     ${regional.routeCount} routes, '
        '${regional.stopCount} stops -> kept $keptRoutes routes, '
        '${merged.stopCount - index.stopCount} new stops');
  }
  index = merged;

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
