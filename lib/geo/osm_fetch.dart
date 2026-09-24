/// 9.1 — Overpass fetch of the drivable/tram way network over the GTT bbox.
///
/// Split into ~0.1 degree tiles so no single response is huge, each tile cached
/// raw on disk. Fair use: a cached tile is never re-fetched before it is 30
/// days old or the cache version changes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const osmCacheVersion = 2;
const osmTileDegrees = 0.1;
const osmMaxAge = Duration(days: 30);

/// Tiles are queried with this much overlap, so a hop that leaves a tile
/// between two stops still finds road under it. Duplicated ways are harmless:
/// the graph builder drops repeated edges.
const osmTileOverlapDegrees = 0.02;

const osmUserAgent =
    'PiedeMove/0.1 (Turin transit planner; github.com/piedemove)';

/// Mirrors, tried in rotation. `overpass.osm.ch` is deliberately absent: it
/// serves Switzerland only and answers 200 with an empty element list.
const osmEndpoints = <String>[
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];

/// Every `highway` way plus tram track. A regex over the highway values made
/// Overpass time out (HTTP 504) on rural tiles; an unfiltered key lookup is
/// far cheaper server side, and `wayInMode` drops what the graph cannot use.
String overpassQuery(double s, double w, double n, double e) {
  final bbox = '${s.toStringAsFixed(5)},${w.toStringAsFixed(5)},'
      '${n.toStringAsFixed(5)},${e.toStringAsFixed(5)}';
  return '[out:json][timeout:180];'
      '(way["highway"]($bbox);'
      'way["railway"="tram"]($bbox););'
      'out geom;';
}

class OsmTile {
  const OsmTile(this.s, this.w, this.n, this.e);
  final double s, w, n, e;

  /// Gzipped: the raw responses are ~10 MB each and only the build reads them.
  String get name => 'osm_v$osmCacheVersion'
      '_${(s * 10).round()}_${(w * 10).round()}.json.gz';
}

List<OsmTile> tilesFor(double minLat, double minLon, double maxLat,
    double maxLon, {double pad = 0.02}) {
  final s0 = ((minLat - pad) / osmTileDegrees).floor();
  final w0 = ((minLon - pad) / osmTileDegrees).floor();
  final s1 = ((maxLat + pad) / osmTileDegrees).ceil();
  final w1 = ((maxLon + pad) / osmTileDegrees).ceil();
  return [
    for (var y = s0; y < s1; y++)
      for (var x = w0; x < w1; x++)
        OsmTile(y * osmTileDegrees, x * osmTileDegrees,
            (y + 1) * osmTileDegrees, (x + 1) * osmTileDegrees),
  ];
}

typedef OsmLog = void Function(String message);

/// Downloads every missing or stale tile into [cacheDir] and returns the files
/// that are usable. A tile that cannot be fetched at all is left out: the
/// caller falls back to `shapes.txt` geometry for anything it cannot snap.
Future<List<File>> fetchOsmTiles(
  List<OsmTile> tiles, {
  required Directory cacheDir,
  Duration maxAge = osmMaxAge,
  bool force = false,
  OsmLog? log,
  http.Client? client,
}) async {
  cacheDir.createSync(recursive: true);
  final owned = client == null;
  final http.Client c = client ?? http.Client();
  final out = <File>[];
  try {
    for (final tile in tiles) {
      final file = File('${cacheDir.path}/${tile.name}');
      final fresh = file.existsSync() &&
          file.lengthSync() > 2048 &&
          DateTime.now().difference(file.lastModifiedSync()) < maxAge;
      if (fresh && !force) {
        out.add(file);
        continue;
      }
      // Polite pacing: the public instances rate limit per IP.
      await Future<void>.delayed(const Duration(seconds: 15));
      var body = await _fetchTile(c, tile, log);
      // A tile Overpass cannot serve whole (dense area, 504) is fetched as
      // four quadrants and stitched: same ways, smaller queries.
      body ??= await _fetchQuadrants(c, tile, log);
      if (body == null) {
        // Keep a stale tile rather than nothing.
        if (file.existsSync()) out.add(file);
        continue;
      }
      await file.writeAsBytes(gzip.encode(utf8.encode(body)), flush: true);
      out.add(file);
    }
  } finally {
    if (owned) c.close();
  }
  return out;
}

Future<String?> _fetchQuadrants(http.Client c, OsmTile tile, OsmLog? log) async {
  final midLat = (tile.s + tile.n) / 2, midLon = (tile.w + tile.e) / 2;
  final seen = <String>{};
  final elements = <dynamic>[];
  for (final q in [
    OsmTile(tile.s, tile.w, midLat, midLon),
    OsmTile(tile.s, midLon, midLat, tile.e),
    OsmTile(midLat, tile.w, tile.n, midLon),
    OsmTile(midLat, midLon, tile.n, tile.e),
  ]) {
    await Future<void>.delayed(const Duration(seconds: 15));
    final body = await _fetchTile(c, q, log, name: '${tile.name} quadrant');
    if (body == null) return null; // a partial tile would hide roads silently
    for (final e in (jsonDecode(body)['elements'] as List)) {
      if (seen.add('${e['type']}/${e['id']}')) elements.add(e);
    }
  }
  return jsonEncode({'elements': elements});
}

Future<String?> _fetchTile(http.Client c, OsmTile tile, OsmLog? log,
    {String? name}) async {
  final label = name ?? tile.name;
  final query = overpassQuery(tile.s - osmTileOverlapDegrees,
      tile.w - osmTileOverlapDegrees, tile.n + osmTileOverlapDegrees,
      tile.e + osmTileOverlapDegrees);
  // The main instance is by far the fastest; a rate limit is worth waiting
  // out before falling back to a slower mirror.
  const order = [0, 0, 0, 1, 2];
  for (var attempt = 0; attempt < order.length; attempt++) {
    final endpoint = osmEndpoints[order[attempt]];
    try {
      final r = await c
          .post(Uri.parse(endpoint),
              headers: {
                'User-Agent': osmUserAgent,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: {'data': query})
          .timeout(const Duration(minutes: 2));
      // A mirror that does not hold this area answers 200 with no elements;
      // treat that as a miss and try the next one.
      if (r.statusCode == 200 && r.bodyBytes.length > 2048) {
        log?.call('$label ${(r.bodyBytes.length / 1e6).toStringAsFixed(1)} MB');
        return r.body;
      }
      log?.call('$label HTTP ${r.statusCode} from $endpoint');
      if (r.statusCode == 429) {
        // Overpass is rate limiting: back off well beyond the usual retry.
        await Future<void>.delayed(const Duration(seconds: 60));
      }
    } catch (e) {
      log?.call('$label $endpoint failed: $e');
    }
    await Future<void>.delayed(const Duration(seconds: 10));
  }
  return null;
}

/// One Overpass call for the metro and funicular tracks inside a bbox (those
/// modes have no shape in the feed and run on their own rails). Cached like a
/// tile; null when it cannot be fetched, and the caller draws the stop chain,
/// marked approximate.
Future<File?> fetchRailWays(double s, double w, double n, double e,
    {required Directory cacheDir, bool force = false, OsmLog? log, http.Client? client}) async {
  cacheDir.createSync(recursive: true);
  final name = 'rail_v1_${(s * 100).round()}_${(w * 100).round()}_'
      '${(n * 100).round()}_${(e * 100).round()}.json.gz';
  final file = File('${cacheDir.path}/$name');
  if (!force &&
      file.existsSync() &&
      file.lengthSync() > 200 &&
      DateTime.now().difference(file.lastModifiedSync()) < osmMaxAge) {
    return file;
  }
  final owned = client == null;
  final c = client ?? http.Client();
  try {
    final bbox = '${s.toStringAsFixed(5)},${w.toStringAsFixed(5)},'
        '${n.toStringAsFixed(5)},${e.toStringAsFixed(5)}';
    final query = '[out:json][timeout:120];'
        'way["railway"~"^(subway|light_rail|funicular|monorail)\$"]($bbox);'
        'out geom;';
    for (final endpoint in osmEndpoints) {
      try {
        final r = await c
            .post(Uri.parse(endpoint),
                headers: {
                  'User-Agent': osmUserAgent,
                  'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: {'data': query})
            .timeout(const Duration(minutes: 2));
        if (r.statusCode == 200 && r.bodyBytes.length > 200) {
          await file.writeAsBytes(gzip.encode(r.bodyBytes), flush: true);
          log?.call('$name ${(r.bodyBytes.length / 1e3).round()} kB');
          return file;
        }
        log?.call('$name HTTP ${r.statusCode} from $endpoint');
      } catch (err) {
        log?.call('$name $endpoint failed: $err');
      }
    }
  } finally {
    if (owned) c.close();
  }
  return file.existsSync() ? file : null;
}
