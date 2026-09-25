/// Writes `build/lines_release/manifest.json` for the `lines-latest` release:
/// format, the GTT feed the geometry was built from, build time, and each
/// file's size and sha256. The app (`lib/geo/lines_update.dart`) reads it.
///
///     dart tool/lines_manifest.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:piedemove/geo/lines_io.dart';

const releaseDir = 'build/lines_release';
const files = ['lines.bin.gz', 'ambient.json.gz', 'connectors.json.gz'];

Future<void> main() async {
  final net = await readLinesFile('build/lines.bin');
  if (net == null) {
    stderr.writeln('no usable build/lines.bin');
    exit(1);
  }
  Directory(releaseDir).createSync(recursive: true);
  final entries = <String, dynamic>{};
  for (final name in files) {
    final src = File('assets/$name');
    final bytes = src.readAsBytesSync();
    src.copySync('$releaseDir/$name');
    entries[name] = {
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
  }
  final manifest = {
    'format': linesFormatVersion,
    'feedVersion': net.feedVersion,
    'built': DateTime.now().toUtc().toIso8601String(),
    'patterns': net.patterns.length,
    'files': entries,
  };
  File('$releaseDir/manifest.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  stdout.writeln(jsonEncode(manifest));
}
