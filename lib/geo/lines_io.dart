/// `lines.bin` — snapped pattern geometry, versioned and keyed to the feed.
///
/// Its own file, separate from `index.bin`: a missing or stale lines file
/// costs the map its lines and nothing else, routing never reads it.
library;

import 'dart:io';
import 'dart:typed_data';

import '../data/index_io.dart';
import 'pattern_snap.dart';

const linesFormatVersion = 1;
const _magic = 0x504D4C31; // "PML1"

class LineNetwork {
  LineNetwork(this.feedVersion, this.patterns, {this.osmApproximate = false});

  final String feedVersion;

  /// Snapped patterns, in pattern-id order; patterns with no geometry absent.
  final List<SnappedPattern> patterns;

  /// True when OSM was unreachable and geometry came from `shapes.txt`: every
  /// line is then approximate.
  final bool osmApproximate;

  Map<int, SnappedPattern>? _byPattern;
  SnappedPattern? operator [](int pattern) =>
      (_byPattern ??= {for (final p in patterns) p.pattern: p})[pattern];
}

Uint8List encodeLines(LineNetwork net) {
  final w = BinWriter()
    ..int32(_magic)
    ..int32(linesFormatVersion);
  w.strings([net.feedVersion]);
  w
    ..int32(net.osmApproximate ? 1 : 0)
    ..int32(net.patterns.length);
  for (final p in net.patterns) {
    w.int32(p.pattern);
    w
      ..i32(p.vertexLat)
      ..i32(p.vertexLon);
    w.i64(p.vertexWay);
    w.u8(p.vertexDir);
    w
      ..i32(p.stopVertex)
      ..i32(p.stopLat)
      ..i32(p.stopLon);
    w.u8(p.hopApprox);
  }
  return w.take();
}

/// Returns null when the file is from another format version or feed.
LineNetwork? decodeLines(Uint8List data, {String? feedVersion}) {
  final r = BinReader(data);
  if (r.int32() != _magic) return null;
  if (r.int32() != linesFormatVersion) return null;
  final feed = r.strings().first;
  if (feedVersion != null && feed != feedVersion) return null;
  final approximate = r.int32() != 0;
  final count = r.int32();
  final patterns = <SnappedPattern>[];
  for (var i = 0; i < count; i++) {
    final id = r.int32();
    patterns.add(SnappedPattern(
      pattern: id,
      vertexLat: r.i32(),
      vertexLon: r.i32(),
      vertexWay: r.i64(),
      vertexDir: r.u8(),
      stopVertex: r.i32(),
      stopLat: r.i32(),
      stopLon: r.i32(),
      hopApprox: r.u8(),
    ));
  }
  return LineNetwork(feed, patterns, osmApproximate: approximate);
}

Future<void> writeLinesFile(LineNetwork net, String path) async {
  final tmp = File('$path.tmp');
  await tmp.writeAsBytes(encodeLines(net), flush: true);
  await tmp.rename(path);
}

Future<LineNetwork?> readLinesFile(String path, {String? feedVersion}) async {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    return decodeLines(await file.readAsBytes(), feedVersion: feedVersion);
  } catch (_) {
    return null; // Corrupt lines file: the map simply has no lines.
  }
}
