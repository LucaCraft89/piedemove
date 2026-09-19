/// Streaming access to the members of a GTFS zip.
///
/// Never decompresses a whole member into memory: each member is inflated to a
/// temporary file and read back line by line, so peak memory stays flat even
/// for the 99 MB `stop_times.txt`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

class GtfsZip {
  GtfsZip(this.zipPath, this.workDir);

  final String zipPath;
  final Directory workDir;

  Archive? _archive;

  Archive get _open =>
      _archive ??= ZipDecoder().decodeStream(InputFileStream(zipPath));

  bool has(String member) => _find(member) != null;

  ArchiveFile? _find(String member) {
    for (final f in _open.files) {
      if (!f.isFile) continue;
      final name = f.name.split('/').last;
      if (name == member) return f;
    }
    return null;
  }

  /// Inflates [member] to a temp file and yields its lines. Missing optional
  /// members yield nothing.
  Stream<String> lines(String member) async* {
    final entry = _find(member);
    if (entry == null) return;
    final tmp = File('${workDir.path}/_$member');
    final out = OutputFileStream(tmp.path);
    entry.writeContent(out);
    await out.close();
    try {
      yield* tmp
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }

  void close() {
    _archive?.clear();
    _archive = null;
  }
}
