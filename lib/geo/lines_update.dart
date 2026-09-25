/// Keeps the line geometry in step with GTT without an app update. Best
/// effort, silent, never in the way of the map or of routing.
///
/// The `lines` workflow rebuilds `lines.bin.gz`, `ambient.json.gz` and
/// `connectors.json.gz` whenever GTT publishes a new export and puts them on
/// the `lines-latest` release with a `manifest.json` (format, feed, size and
/// sha256 of each file). At most once a day, in the foreground, this reads the
/// manifest (`If-None-Match`); a set built from another feed is downloaded into
/// a fresh folder, every file's size and sha256 checked and the geometry
/// decoded, and only then does the one-line `current.json` pointer switch to
/// it - the three files always change together, and any failure leaves the
/// set in use untouched. A set in a format this app cannot read is ignored.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'lines_io.dart';

/// The one place that names the release.
const linesManifestUrl =
    'https://github.com/LucaCraft89/piedemove/releases/download/lines-latest/manifest.json';

const linesUpdateInterval = Duration(days: 1);
const linesUpdateTimeout = Duration(seconds: 30);

/// Refuse anything bigger per file: a manifest may not fill the phone.
const linesUpdateMaxBytes = 64 * 1024 * 1024;

/// The files of a set, as the app's assets are named.
const linesSetFiles = ['lines.bin.gz', 'ambient.json.gz', 'connectors.json.gz'];

const _pointerName = 'current.json';
const _metaName = 'lines_update.json';

class LinesManifest {
  const LinesManifest({
    required this.format,
    required this.feedVersion,
    required this.files,
  });

  final int format;
  final String feedVersion;

  /// File name -> (size, sha256).
  final Map<String, (int, String)> files;

  factory LinesManifest.fromJson(Map<String, dynamic> j) => LinesManifest(
        format: j['format'] as int,
        feedVersion: j['feedVersion'].toString(),
        files: {
          for (final e in (j['files'] as Map).entries)
            e.key as String: (
              (e.value as Map)['size'] as int,
              ((e.value as Map)['sha256'] as String).toLowerCase(),
            ),
        },
      );
}

enum LinesUpdateResult { tooSoon, current, updated, incompatible, failed }

/// The downloaded set in use, if any: its folder and the feed it was built
/// from. Null when none was ever installed or its files are gone.
({Directory dir, String feedVersion})? currentLinesSet(Directory root) {
  try {
    final j = jsonDecode(File('${root.path}/$_pointerName').readAsStringSync())
        as Map<String, dynamic>;
    final dir = Directory('${root.path}/${j['set']}');
    for (final name in linesSetFiles) {
      if (!File('${dir.path}/$name').existsSync()) return null;
    }
    return (dir: dir, feedVersion: j['feedVersion'].toString());
  } catch (_) {
    return null;
  }
}

class LinesUpdater {
  LinesUpdater({
    required this.root,
    this.manifestUrl = linesManifestUrl,
    this.client,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// `<support>/lines`: the sets, the pointer and the check bookkeeping.
  final Directory root;
  final String manifestUrl;
  final http.Client? client;
  final DateTime Function() _now;

  File get _meta => File('${root.path}/$_metaName');

  Map<String, dynamic> _readMeta() {
    try {
      return jsonDecode(_meta.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void _writeMeta(Map<String, dynamic> m) {
    try {
      root.createSync(recursive: true);
      _meta.writeAsStringSync(jsonEncode(m));
    } catch (_) {}
  }

  /// Never throws.
  Future<LinesUpdateResult> checkAndUpdate({bool force = false}) async {
    final c = client ?? http.Client();
    try {
      return await _run(c, force);
    } catch (_) {
      return LinesUpdateResult.failed;
    } finally {
      if (client == null) c.close();
    }
  }

  Future<LinesUpdateResult> _run(http.Client client, bool force) async {
    final meta = _readMeta();
    final last = meta['checkedAt'] as int?;
    if (!force &&
        last != null &&
        _now().millisecondsSinceEpoch - last <
            linesUpdateInterval.inMilliseconds) {
      return LinesUpdateResult.tooSoon;
    }
    final installed = currentLinesSet(root);
    // An ETag only means "you have this" while the set it came with is there.
    final etag = installed == null ? null : meta['etag'] as String?;
    final http.Response r;
    try {
      r = await client.get(Uri.parse(manifestUrl), headers: {
        if (etag != null && !force) 'If-None-Match': etag,
      }).timeout(linesUpdateTimeout);
    } catch (_) {
      return LinesUpdateResult.failed; // offline: not a check, retry later
    }
    meta['checkedAt'] = _now().millisecondsSinceEpoch;
    if (r.statusCode == 304) {
      _writeMeta(meta);
      return LinesUpdateResult.current;
    }
    if (r.statusCode != 200) {
      _writeMeta(meta);
      return LinesUpdateResult.failed;
    }
    final LinesManifest m;
    try {
      m = LinesManifest.fromJson(
          jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      _writeMeta(meta);
      return LinesUpdateResult.failed;
    }
    if (m.format != linesFormatVersion ||
        !linesSetFiles.every(m.files.containsKey)) {
      meta.remove('etag'); // a later app that reads it must still fetch it
      _writeMeta(meta);
      return LinesUpdateResult.incompatible;
    }
    if (installed?.feedVersion == m.feedVersion) {
      meta['etag'] = r.headers['etag'];
      _writeMeta(meta);
      return LinesUpdateResult.current;
    }

    final setName = 'set-${_now().millisecondsSinceEpoch}';
    final dir = Directory('${root.path}/$setName');
    if (!await _download(client, m, dir)) {
      _writeMeta(meta); // no ETag: the next check retries
      return LinesUpdateResult.failed;
    }
    // Switch: write the pointer beside, then rename over (atomic).
    final tmp = File('${root.path}/$_pointerName.tmp');
    tmp.writeAsStringSync(
        jsonEncode({'set': setName, 'feedVersion': m.feedVersion}));
    tmp.renameSync('${root.path}/$_pointerName');
    _prune(keep: setName);
    meta['etag'] = r.headers['etag'];
    _writeMeta(meta);
    return LinesUpdateResult.updated;
  }

  /// Downloads every file of [m] into [dir] and verifies it; false (and [dir]
  /// removed) on any problem.
  Future<bool> _download(http.Client client, LinesManifest m, Directory dir) async {
    try {
      dir.createSync(recursive: true);
      final base = Uri.parse(manifestUrl);
      for (final name in linesSetFiles) {
        final (size, sha) = m.files[name]!;
        if (size <= 0 || size > linesUpdateMaxBytes) throw const FormatException('size');
        final resp = await client
            .send(http.Request('GET', base.resolve(name)))
            .timeout(linesUpdateTimeout);
        if (resp.statusCode != 200) throw const FormatException('http');
        final sink = File('${dir.path}/$name').openWrite();
        var total = 0;
        try {
          await for (final chunk in resp.stream.timeout(linesUpdateTimeout)) {
            total += chunk.length;
            if (total > size) throw const FormatException('too big');
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        final bytes = File('${dir.path}/$name').readAsBytesSync();
        if (bytes.length != size || sha256.convert(bytes).toString() != sha) {
          throw const FormatException('hash');
        }
      }
      // The geometry must decode in this app's format, off the UI thread.
      final gz = File('${dir.path}/lines.bin.gz').readAsBytesSync();
      if (!await _decodesInIsolate(gz)) throw const FormatException('format');
      return true;
    } catch (_) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
      return false;
    }
  }

  /// Older sets go once the pointer has moved on.
  void _prune({required String keep}) {
    try {
      for (final e in root.listSync()) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (e is Directory && name.startsWith('set-') && name != keep) {
          e.deleteSync(recursive: true);
        }
      }
    } catch (_) {}
  }
}

bool _decodes(Uint8List gz) =>
    decodeLines(Uint8List.fromList(gzip.decode(gz))) != null;

// Not async: the isolate closure captures only [gz].
Future<bool> _decodesInIsolate(Uint8List gz) => Isolate.run(() => _decodes(gz));
