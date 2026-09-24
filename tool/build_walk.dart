/// Builds the pedestrian graph from OSM.
///
///     dart tool/build_walk.dart [--bbox S,W,N,E] [--cache build/walk_osm]
///         [--out build/walk_graph.pmwg.gz] [--manifest build/walk_manifest.json]
///         [--asset assets/walk_graph.pmwg.gz] [--url <graph file url>]
///         [--offline] [--input a.json,b.json]
///
/// Input is Overpass JSON: fetched per 0.04 degree tile and cached gzipped
/// under --cache (build time only, the app never calls Overpass for walking),
/// or given with --input / read from the cache with --offline. Same input,
/// same bytes. Output: the gzipped graph, its manifest.json (what the app's
/// updater reads) and, unless --asset is empty, a copy for the shipped assets.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:piedemove/geo/walk_build.dart';
import 'package:piedemove/geo/walk_graph.dart';

const _tileDegrees = 0.04;
const _defaultBbox = [44.985, 7.56, 45.145, 7.79];
const _endpoints = [
  'https://overpass-api.de/api/interpreter',
];

/// A mirror serving a snapshot older than this is as good as failing: mixed
/// data ages inside one graph are worse than a retry.
const _maxAge = Duration(days: 3);

/// Every `highway` way: a regex over the values makes Overpass time out, the
/// bare key is cheap. `classifyWay` drops what pedestrians cannot use.
String _query(double s, double w, double n, double e) =>
    '[out:json][timeout:240];(way["highway"]($s,$w,$n,$e););(._;>;);out body qt;';

Future<void> main(List<String> args) async {
  String opt(String name, String def) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
  }

  final bbox = opt('bbox', _defaultBbox.join(',')).split(',').map(double.parse).toList();
  final cache = Directory(opt('cache', 'build/walk_osm'))..createSync(recursive: true);
  final out = opt('out', 'build/walk_graph.pmwg.gz');
  final manifestPath = opt('manifest', 'build/walk_manifest.json');
  final asset = opt('asset', 'assets/walk_graph.pmwg.gz');
  final url = opt('url', 'walk_graph.pmwg.gz');
  final offline = args.contains('--offline');
  final input = opt('input', '');
  final started = DateTime.now();
  stderr.writeln('start $bbox');

  final data = OsmData();
  if (input.isNotEmpty) {
    for (final f in input.split(',')) {
      data.addOverpass(jsonDecode(_read(File(f))) as Map<String, dynamic>);
    }
  } else {
    final client = http.Client();
    for (var s = bbox[0]; s < bbox[2] - 1e-9; s += _tileDegrees) {
      for (var w = bbox[1]; w < bbox[3] - 1e-9; w += _tileDegrees) {
        final n = (s + _tileDegrees).clamp(bbox[0], bbox[2]).toDouble();
        final e = (w + _tileDegrees).clamp(bbox[1], bbox[3]).toDouble();
        final name = 'tile_${(s * 1000).round()}_${(w * 1000).round()}.json.gz';
        final file = File('${cache.path}/$name');
        if (!file.existsSync()) {
          if (offline) {
            stderr.writeln('missing $name (offline)');
            exit(2);
          }
          stderr.writeln('fetching $name');
          final body = await _fetchTile(client, _r(s), _r(w), _r(n), _r(e));
          file.writeAsBytesSync(gzip.encode(utf8.encode(body)));
          stdout.writeln('fetched $name');
        }
        data.addOverpass(jsonDecode(_read(file)) as Map<String, dynamic>);
      }
    }
    client.close();
  }

  data.clipTo(bbox[0], bbox[1], bbox[2], bbox[3]);
  final graph = buildWalkGraph(data,
      south: bbox[0], west: bbox[1], north: bbox[2], east: bbox[3]);
  final bytes = graph.encode();
  final gz = GZipCodec(level: 9).encode(bytes);
  File(out)
    ..createSync(recursive: true)
    ..writeAsBytesSync(gz);
  if (asset.isNotEmpty) File(asset).writeAsBytesSync(gz);

  final head = WalkHeader.parse(Uint8List.fromList(bytes));
  final date = head.osmDate.toIso8601String().substring(0, 10);
  final manifest = {
    'format': walkGraphFormat,
    'version': date.replaceAll('-', ''),
    'date': head.osmDate.toIso8601String(),
    'bbox': bbox,
    'size': gz.length,
    'sha256': sha256.convert(gz).toString(),
    'payloadSha256': head.sha256Hex,
    'url': url,
  };
  File(manifestPath)
    ..createSync(recursive: true)
    ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(manifest)}\n');
  stdout.writeln('nodes ${graph.nodeCount}  edges ${graph.edgeCount}  '
      'raw ${bytes.length}  gz ${gz.length}  osm $date  '
      'sha256 ${manifest['sha256']}  '
      '${DateTime.now().difference(started).inSeconds}s');
}

double _r(double v) => (v * 1e5).round() / 1e5;

String _read(File f) => f.path.endsWith('.gz')
    ? utf8.decode(gzip.decode(f.readAsBytesSync()))
    : f.readAsStringSync();

/// A tile that keeps failing is fetched as four quadrants and stitched.
Future<String> _fetchTile(http.Client c, double s, double w, double n, double e,
    {int depth = 0}) async {
  try {
    return await _fetch(c, _query(s, w, n, e), attempts: depth == 0 ? 3 : 4);
  } catch (err) {
    if (depth >= 2) rethrow;
    stderr.writeln('splitting $s,$w,$n,$e');
    final ms = (s + n) / 2, mw = (w + e) / 2;
    final parts = <Map<String, dynamic>>[];
    for (final q in [
      [s, w, ms, mw],
      [s, mw, ms, e],
      [ms, w, n, mw],
      [ms, mw, n, e],
    ]) {
      parts.add(jsonDecode(await _fetchTile(c, q[0], q[1], q[2], q[3], depth: depth + 1))
          as Map<String, dynamic>);
    }
    return jsonEncode({
      'osm3s': {
        'timestamp_osm_base': ([
          for (final p in parts) (p['osm3s'] as Map)['timestamp_osm_base'] as String
        ]..sort()).first,
      },
      'elements': [for (final p in parts) ...p['elements'] as List],
    });
  }
}

Future<String> _fetch(http.Client c, String query, {int attempts = 6}) async {
  Object? last;
  for (var attempt = 0; attempt < attempts; attempt++) {
    final url = _endpoints[attempt % _endpoints.length];
    try {
      final r = await c
          .post(Uri.parse(url),
              headers: {'User-Agent': 'PiedeMove-build/0.1 (walk graph)'},
              body: {'data': query})
          .timeout(const Duration(minutes: 5));
      if (r.statusCode == 200 && r.body.contains('"elements"')) {
        final ts = RegExp(r'"timestamp_osm_base": "([^"]+)"').firstMatch(r.body)?.group(1);
        final t = ts == null ? null : DateTime.tryParse(ts);
        if (t == null || DateTime.now().toUtc().difference(t) < _maxAge) return r.body;
        last = 'stale snapshot $ts';
      } else {
        last = 'HTTP ${r.statusCode}';
      }
    } catch (e) {
      last = e;
    }
    stderr.writeln('overpass attempt ${attempt + 1} failed: $last');
    await Future<void>.delayed(Duration(seconds: 5 * (attempt + 1)));
  }
  throw StateError('Overpass failed: $last');
}
