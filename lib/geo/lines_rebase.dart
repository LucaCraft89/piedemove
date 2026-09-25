/// Puts pattern geometry built from one GTT export onto the index the phone
/// has now, which may come from a newer one.
///
/// GTT renumbers patterns with every export, so geometry is matched by
/// [patternSignature] (line, mode, stop sequence), never by number. A pattern
/// with no geometry - a new or rerouted line, a regional bus, or no lines file
/// at all - is drawn through its stops with straight dotted hops: marked
/// approximate, never silently guessed, and replaced as soon as a lines build
/// covering it arrives (see `lines_update.dart`).
library;

import 'dart:typed_data';

import '../data/transit_index.dart';
import 'lines_io.dart';
import 'pattern_snap.dart';

/// Result of [rebaseLines]: the network keyed by the current index's pattern
/// numbers, and how many patterns kept real geometry.
typedef RebasedLines = ({LineNetwork net, int matched, int synthetic});

RebasedLines rebaseLines(LineNetwork? source, TransitIndex ix) {
  // Format 1 has no signatures: its numbers only mean something for its own
  // feed. Format 2 is matched by signature whatever the feed.
  final byNumber = source != null &&
      source.signatures == null &&
      source.feedVersion == ix.feedVersion;
  final bySignature = <String, SnappedPattern>{};
  final sigs = source?.signatures;
  if (source != null && sigs != null) {
    for (var i = 0; i < source.patterns.length; i++) {
      bySignature[sigs[i]] = source.patterns[i];
    }
  }

  final out = <SnappedPattern>[];
  var matched = 0, synthetic = 0;
  for (var p = 0; p < ix.patternCount; p++) {
    final len = ix.patternLength(p);
    if (len < 2) continue;
    final geom = byNumber
        ? source[p]
        : bySignature.isEmpty
            ? null
            : bySignature[patternSignature(ix, p)];
    // A signature match has the same stop count by construction; the check
    // guards a format 1 file whose numbers drifted anyway.
    if (geom != null && geom.stopVertex.length == len && !geom.synthetic) {
      out.add(geom.pattern == p ? geom : geom.withPattern(p));
      matched++;
    } else {
      out.add(stopChordPattern(ix, p));
      synthetic++;
    }
  }
  return (
    net: LineNetwork(ix.feedVersion, out,
        osmApproximate: source?.osmApproximate ?? true),
    matched: matched,
    synthetic: synthetic,
  );
}

/// Pattern [p] drawn as its stops joined by straight segments, every hop
/// flagged approximate.
SnappedPattern stopChordPattern(TransitIndex ix, int p) {
  final len = ix.patternLength(p);
  final lat = Int32List(len), lon = Int32List(len);
  for (var i = 0; i < len; i++) {
    final s = ix.patternStopAt(p, i);
    lat[i] = microdeg(ix.stopLat[s]);
    lon[i] = microdeg(ix.stopLon[s]);
  }
  return SnappedPattern(
    pattern: p,
    vertexLat: lat,
    vertexLon: lon,
    vertexWay: Int64List(len)..fillRange(0, len, -1),
    vertexDir: Uint8List(len),
    stopVertex: Int32List.fromList([for (var i = 0; i < len; i++) i]),
    stopLat: Int32List.fromList(lat),
    stopLon: Int32List.fromList(lon),
    hopApprox: Uint8List(len - 1)..fillRange(0, len - 1, 1),
    synthetic: true,
  );
}
