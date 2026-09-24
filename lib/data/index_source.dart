/// Getting a [TransitIndex] onto the phone.
///
/// There is no backend: the device downloads the GTT zip itself, builds the
/// binary index in a background isolate and caches it. A cached index younger
/// than [maxIndexAge] is used as is; an older one is refreshed, and kept when
/// the refresh fails, so the planner works with every feed down.
library;

import 'dart:io';
import 'dart:isolate';

import 'download.dart';
import 'feeds.dart';
import 'gtfs_zip.dart';
import 'index_build.dart';
import 'index_merge.dart';
import 'index_io.dart';
import 'transit_index.dart';

const maxIndexAge = Duration(days: 7);

/// A static-feed download that sends nothing for this long is abandoned.
const feedStallTimeout = Duration(seconds: 60);

enum IndexStage { cached, downloading, building, ready }

typedef StageSink = void Function(IndexStage stage);

class IndexStore {
  IndexStore(this.dir);

  /// Application support directory; survives app restarts, not uninstalls.
  final Directory dir;

  String get indexPath => '${dir.path}/index.bin';
  String get zipPath => '${dir.path}/gtt_gtfs.zip';
  String get regionalZipPath => '${dir.path}/piemonte_bus.zip';

  Future<TransitIndex> load({StageSink? onStage}) async {
    final cached = File(indexPath);
    final fresh = cached.existsSync() &&
        DateTime.now().difference(cached.lastModifiedSync()) < maxIndexAge;
    if (fresh) {
      onStage?.call(IndexStage.cached);
      final ix = await readIndexFile(indexPath);
      if (ix != null) {
        onStage?.call(IndexStage.ready);
        return ix;
      }
    }

    try {
      onStage?.call(IndexStage.downloading);
      dir.createSync(recursive: true);
      await downloadToFile(Feeds.gttStaticGtfs, zipPath,
          timeout: feedStallTimeout);

      // Scheduled-only regional buses (phase 9). Best effort: the planner has
      // to work when this feed is down, so a failure just means GTT only.
      String? regional;
      try {
        await downloadToFile(Feeds.piemonteBusGtfs, regionalZipPath,
            timeout: feedStallTimeout);
        regional = regionalZipPath;
      } catch (_) {
        regional = null;
      }

      onStage?.call(IndexStage.building);
      final zip = zipPath;
      final out = indexPath;
      final work = dir.path;
      await Isolate.run(() => _buildToFile(zip, work, out, regional));
      File(zipPath).deleteSync();
      if (File(regionalZipPath).existsSync()) {
        File(regionalZipPath).deleteSync();
      }
    } catch (_) {
      // Feed unreachable or corrupt: any cached index still beats nothing.
      final ix = cached.existsSync() ? await readIndexFile(indexPath) : null;
      if (ix == null) rethrow;
      onStage?.call(IndexStage.ready);
      return ix;
    }

    final ix = await readIndexFile(indexPath);
    if (ix == null) throw const IndexUnavailable();
    onStage?.call(IndexStage.ready);
    return ix;
  }
}

class IndexUnavailable implements Exception {
  const IndexUnavailable();
  @override
  String toString() => 'IndexUnavailable: no usable index on the device';
}

/// Runs in a background isolate: parse the zip(s), write `index.bin`.
Future<void> _buildToFile(String zipPath, String workDir, String outPath,
    [String? regionalZipPath]) async {
  final source = GtfsZip(zipPath, Directory(workDir));
  try {
    var index = await buildIndex(source);
    if (regionalZipPath != null) {
      final regional = GtfsZip(regionalZipPath, Directory(workDir));
      try {
        index = mergeRegional(index, await buildIndex(regional));
      } catch (_) {
        // A broken regional feed never costs the user the GTT index.
      } finally {
        regional.close();
      }
    }
    await writeIndexFile(index, outPath);
  } finally {
    source.close();
  }
}
