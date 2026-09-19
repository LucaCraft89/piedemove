/// Getting a [TransitIndex] onto the phone.
///
/// There is no backend: the device downloads the GTT zip itself, builds the
/// binary index in a background isolate and caches it. A cached index younger
/// than [maxIndexAge] is used as is; an older one is refreshed, and kept when
/// the refresh fails, so the planner works with every feed down.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import 'feeds.dart';
import 'gtfs_zip.dart';
import 'index_build.dart';
import 'index_io.dart';
import 'transit_index.dart';

const maxIndexAge = Duration(days: 7);

enum IndexStage { cached, downloading, building, ready }

typedef StageSink = void Function(IndexStage stage);

class IndexStore {
  IndexStore(this.dir);

  /// Application support directory; survives app restarts, not uninstalls.
  final Directory dir;

  String get indexPath => '${dir.path}/index.bin';
  String get zipPath => '${dir.path}/gtt_gtfs.zip';

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
      final response = await http
          .get(Uri.parse(Feeds.gttStaticGtfs))
          .timeout(const Duration(minutes: 5));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', 
            uri: Uri.parse(Feeds.gttStaticGtfs));
      }
      dir.createSync(recursive: true);
      await File(zipPath).writeAsBytes(response.bodyBytes, flush: true);

      onStage?.call(IndexStage.building);
      final zip = zipPath;
      final out = indexPath;
      final work = dir.path;
      await Isolate.run(() => _buildToFile(zip, work, out));
      File(zipPath).deleteSync();
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

/// Runs in a background isolate: parse the zip, write `index.bin`.
Future<void> _buildToFile(String zipPath, String workDir, String outPath) async {
  final source = GtfsZip(zipPath, Directory(workDir));
  try {
    final index = await buildIndex(source);
    await writeIndexFile(index, outPath);
  } finally {
    source.close();
  }
}
