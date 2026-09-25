/// Prints the GTT feed version of `build/index.bin` (the `lines` workflow's
/// "has GTT published something new?" check).
///
///     dart tool/index_feed.dart
library;

import 'dart:io';

import 'package:piedemove/data/index_io.dart';

Future<void> main() async {
  final ix = await readIndexFile('build/index.bin');
  if (ix == null) {
    stderr.writeln('no usable build/index.bin');
    exit(1);
  }
  stdout.writeln(ix.feedVersion);
}
