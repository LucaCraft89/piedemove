/// `lines.bin` — snapped pattern geometry, versioned.
///
/// Its own file, separate from `index.bin`: a missing or stale lines file
/// costs the map its lines and nothing else, routing never reads it.
///
/// Format 2 stores a [patternSignature] per pattern, so geometry built from one
/// GTT export still finds its patterns in the next (pattern *numbers* change
/// with every export; line, mode and stop sequence only when the line does).
/// See [rebaseLines] in `lines_rebase.dart`.
library;

import 'dart:io';
import 'dart:typed_data';

import '../data/index_io.dart';
import '../data/transit_index.dart';
import 'pattern_snap.dart';

/// 2: a signature string per pattern (after the pattern count).
const linesFormatVersion = 2;

/// Stable identity of pattern [p]: line number, mode and stop ids in order.
String patternSignature(TransitIndex ix, int p) {
  final route = ix.patternRoute[p];
  final b = StringBuffer()
    ..write(ix.routeShortNames[route])
    ..write('|')
    ..write(ix.routeTypes[route])
    ..write('|');
  for (var i = 0; i < ix.patternLength(p); i++) {
    if (i > 0) b.write(',');
    b.write(ix.stopIds[ix.patternStopAt(p, i)]);
  }
  return b.toString();
}
const _magic = 0x504D4C31; // "PML1"

class LineNetwork {
  LineNetwork(this.feedVersion, this.patterns,
      {this.osmApproximate = false, this.signatures});

  final String feedVersion;

  /// [patternSignature] of each entry of [patterns], same order; null for a
  /// format 1 file (then only its own feed's pattern numbers identify them).
  final List<String>? signatures;

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
  final sigs = net.signatures;
  if (sigs == null || sigs.length != net.patterns.length) {
    throw ArgumentError('lines.bin v$linesFormatVersion needs a signature per pattern');
  }
  w.strings(sigs);
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

/// Returns null when the file is from an unknown format version, or (when
/// [feedVersion] is given) from another feed. Reads formats 1 and 2.
LineNetwork? decodeLines(Uint8List data, {String? feedVersion}) {
  final r = BinReader(data);
  if (r.int32() != _magic) return null;
  final version = r.int32();
  if (version != 1 && version != linesFormatVersion) return null;
  final feed = r.strings().first;
  if (feedVersion != null && feed != feedVersion) return null;
  final approximate = r.int32() != 0;
  final count = r.int32();
  final signatures = version >= 2 ? r.strings() : null;
  // A truncated or hand-made file: one signature per pattern, or nothing.
  if (signatures != null && signatures.length != count) return null;
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
  return LineNetwork(feed, patterns,
      osmApproximate: approximate, signatures: signatures);
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
