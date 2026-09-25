/// Prints the padded bounding box of the GTT network in `build/index.bin` as
/// `west,south,east,north` (osmium's `--bbox` order), so the CI extract covers
/// exactly what the feed serves - no coordinates written down anywhere.
///
///     dart tool/lines_bbox.dart [pad-degrees]
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:piedemove/data/index_io.dart';

Future<void> main(List<String> args) async {
  final pad = args.isEmpty ? 0.03 : double.parse(args.first);
  final ix = await readIndexFile('build/index.bin');
  if (ix == null) {
    stderr.writeln('no usable build/index.bin - run tool/build_index.dart first');
    exit(1);
  }
  var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
  for (var p = 0; p < ix.patternCount; p++) {
    if (ix.patternScheduledOnly(p)) continue; // lines are drawn for GTT only
    for (var i = 0; i < ix.patternLength(p); i++) {
      final st = ix.patternStopAt(p, i);
      s = math.min(s, ix.stopLat[st]);
      n = math.max(n, ix.stopLat[st]);
      w = math.min(w, ix.stopLon[st]);
      e = math.max(e, ix.stopLon[st]);
    }
  }
  if (s > n) {
    stderr.writeln('no GTT patterns in the index');
    exit(1);
  }
  String f(double v) => v.toStringAsFixed(4);
  stdout.writeln('${f(w - pad)},${f(s - pad)},${f(e + pad)},${f(n + pad)}');
}
