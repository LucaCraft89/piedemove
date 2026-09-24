/// Keeps the on-disk walking graph fresh. Best effort, silent, never in the
/// way of routing.
///
/// Reads a small `manifest.json` from [walkManifestUrl] (a GitHub Release
/// asset that may not exist yet: any failure means "keep what we have"), at
/// most once a day, with `If-None-Match`. A newer graph is downloaded to a
/// temp file, its sha256 and its format are verified, then it is renamed over
/// the old one, so an interrupted or corrupt download leaves the previous
/// file untouched. A graph in a format this app cannot read is ignored.
///
/// Callers run it in the foreground only. There is no connectivity plugin in
/// the app: "only when connected" is a request that fails fast and quietly.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'walk_graph.dart';

/// Where the manifest lives. The one place to change when the release
/// workflow (phase 5c) picks its final location.
const walkManifestUrl =
    'https://github.com/piedemove/piedemove/releases/download/walk-graph-latest/manifest.json';

const walkUpdateInterval = Duration(days: 1);
const walkUpdateTimeout = Duration(seconds: 20);

/// Refuse anything bigger: a manifest is not allowed to fill the phone.
const walkUpdateMaxBytes = 64 * 1024 * 1024;

const walkDownloadedName = 'walk_graph.pmwg.gz';
const _metaName = 'walk_update.json';

class WalkManifest {
  const WalkManifest({
    required this.format,
    required this.version,
    required this.date,
    required this.sha256,
    required this.size,
    required this.url,
    this.bbox = const [],
  });

  final int format;
  final String version;
  final DateTime date;
  final String sha256;
  final int size;
  final String url;
  final List<double> bbox;

  factory WalkManifest.fromJson(Map<String, dynamic> j) => WalkManifest(
        format: j['format'] as int,
        version: j['version'].toString(),
        date: DateTime.parse(j['date'] as String),
        sha256: (j['sha256'] as String).toLowerCase(),
        size: j['size'] as int,
        url: j['url'] as String,
        bbox: [for (final v in (j['bbox'] as List? ?? const [])) (v as num).toDouble()],
      );
}

enum WalkUpdateResult {
  /// Checked less than a day ago.
  tooSoon,

  /// Manifest unchanged (304) or not newer than what we have.
  current,

  /// A newer graph is now on disk.
  updated,

  /// Newer but in a format this app cannot read.
  incompatible,

  /// Network, HTTP, hash or format problem: previous graph untouched.
  failed,
}

class WalkGraphUpdater {
  WalkGraphUpdater({
    required this.dir,
    required this.currentOsmTime,
    this.manifestUrl = walkManifestUrl,
    this.client,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Folder holding the downloaded graph and the check bookkeeping.
  final Directory dir;

  /// OSM time (unix seconds) of the graph in use; only newer data is fetched.
  final int Function() currentOsmTime;
  final String manifestUrl;
  final http.Client? client;
  final DateTime Function() _now;

  File get graphFile => File('${dir.path}/$walkDownloadedName');
  File get _meta => File('${dir.path}/$_metaName');

  Map<String, dynamic> _readMeta() {
    try {
      return jsonDecode(_meta.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void _writeMeta(Map<String, dynamic> m) {
    try {
      dir.createSync(recursive: true);
      _meta.writeAsStringSync(jsonEncode(m));
    } catch (_) {}
  }

  /// Never throws.
  Future<WalkUpdateResult> checkAndUpdate({bool force = false}) async {
    final client = this.client ?? http.Client();
    try {
      return await _run(client, force);
    } catch (_) {
      return WalkUpdateResult.failed;
    } finally {
      if (this.client == null) client.close();
    }
  }

  Future<WalkUpdateResult> _run(http.Client client, bool force) async {
    final meta = _readMeta();
    final last = meta['checkedAt'] as int?;
    if (!force &&
        last != null &&
        _now().millisecondsSinceEpoch - last < walkUpdateInterval.inMilliseconds) {
      return WalkUpdateResult.tooSoon;
    }
    final etag = meta['etag'] as String?;
    final http.Response r;
    try {
      r = await client.get(Uri.parse(manifestUrl), headers: {
        if (etag != null && !force) 'If-None-Match': etag,
      }).timeout(walkUpdateTimeout);
    } catch (_) {
      return WalkUpdateResult.failed; // offline: not a check, try again later
    }
    meta['checkedAt'] = _now().millisecondsSinceEpoch;
    if (r.statusCode == 304) {
      _writeMeta(meta);
      return WalkUpdateResult.current;
    }
    if (r.statusCode != 200) {
      _writeMeta(meta);
      return WalkUpdateResult.failed;
    }
    final WalkManifest m;
    try {
      m = WalkManifest.fromJson(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      _writeMeta(meta);
      return WalkUpdateResult.failed;
    }
    if (m.format != walkGraphFormat) {
      meta['etag'] = r.headers['etag'];
      _writeMeta(meta);
      return WalkUpdateResult.incompatible;
    }
    if (m.date.millisecondsSinceEpoch ~/ 1000 <= currentOsmTime() ||
        m.size <= 0 ||
        m.size > walkUpdateMaxBytes) {
      meta['etag'] = r.headers['etag'];
      _writeMeta(meta);
      return WalkUpdateResult.current;
    }

    final ok = await _download(client, Uri.parse(manifestUrl).resolve(m.url), m);
    if (!ok) {
      _writeMeta(meta); // etag not stored: the manifest is retried next time
      return WalkUpdateResult.failed;
    }
    meta['etag'] = r.headers['etag'];
    meta['version'] = m.version;
    _writeMeta(meta);
    return WalkUpdateResult.updated;
  }

  /// Downloads to a temp file, verifies, then renames. False on any problem.
  Future<bool> _download(http.Client client, Uri url, WalkManifest m) async {
    dir.createSync(recursive: true);
    final tmp = File('${graphFile.path}.tmp');
    IOSink? sink;
    try {
      final resp = await client.send(http.Request('GET', url)).timeout(walkUpdateTimeout);
      if (resp.statusCode != 200) return false;
      sink = tmp.openWrite();
      var total = 0;
      await for (final chunk in resp.stream.timeout(walkUpdateTimeout)) {
        total += chunk.length;
        if (total > walkUpdateMaxBytes) throw const FormatException('too big');
        sink.add(chunk);
      }
      await sink.close();
      sink = null;
      final bytes = tmp.readAsBytesSync();
      if (bytes.length != m.size || sha256.convert(bytes).toString() != m.sha256) {
        tmp.deleteSync();
        return false;
      }
      final graph = WalkGraph.decode(Uint8List.fromList(gzip.decode(bytes)));
      if (graph.header.format != walkGraphFormat) {
        tmp.deleteSync();
        return false;
      }
      tmp.renameSync(graphFile.path); // atomic on the same filesystem
      return true;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      return false;
    }
  }
}

/// Reads a gzipped graph file. Null when missing, corrupt or in a format this
/// app does not read: the caller falls back to the next source.
WalkGraph? readWalkGraphFile(File f) {
  try {
    if (!f.existsSync()) return null;
    return WalkGraph.decode(Uint8List.fromList(gzip.decode(f.readAsBytesSync())));
  } catch (_) {
    return null;
  }
}

/// Reads gzipped graph bytes (an asset).
WalkGraph? readWalkGraphBytes(Uint8List gz) {
  try {
    return WalkGraph.decode(Uint8List.fromList(gzip.decode(gz)));
  } catch (_) {
    return null;
  }
}

/// The layering rule in one place: a valid downloaded graph wins, else the
/// shipped bytes, else null. Returns the graph and its origin.
(WalkGraph, String)? loadWalkLayers({File? downloaded, Uint8List? shipped}) {
  final d = downloaded == null ? null : readWalkGraphFile(downloaded);
  if (d != null) return (d, 'downloaded');
  final s = shipped == null ? null : readWalkGraphBytes(shipped);
  return s == null ? null : (s, 'asset');
}
