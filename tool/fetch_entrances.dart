/// Metro entrances (§10.5): one Overpass query around the metro stops of the
/// index -> `assets/entrances.json.gz`.
///
///     dart tool/fetch_entrances.dart
///
/// Built on the desktop like every other line asset: entrances move about as
/// often as the metro itself, so the phone never queries Overpass.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/osm_fetch.dart';

const indexPath = 'build/index.bin';
const assetPath = 'assets/entrances.json.gz';
const aroundMetres = 150;

Future<void> main() async {
  final ix = await readIndexFile(indexPath);
  if (ix == null) {
    stderr.writeln('no usable $indexPath - run tool/build_index.dart first');
    exit(1);
  }

  final metro = <int>[
    for (var s = 0; s < ix.stopCount; s++)
      if (ix.routesAt(s).any((r) => ix.routeTypes[r] == RouteType.metro)) s,
  ];
  stdout.writeln('metro stops ${metro.length}');
  if (metro.isEmpty) exit(1);

  final query = StringBuffer('[out:json][timeout:180];(');
  for (final s in metro) {
    query.write('node(around:$aroundMetres,'
        '${ix.stopLat[s].toStringAsFixed(5)},'
        '${ix.stopLon[s].toStringAsFixed(5)})[railway=subway_entrance];');
  }
  query.write(');out body;');

  final body = await _post(query.toString());
  if (body == null) {
    stderr.writeln('overpass unreachable - asset left as is');
    exit(1);
  }

  final elements =
      (jsonDecode(body) as Map<String, dynamic>)['elements'] as List;
  final features = [
    for (final e in elements.cast<Map<String, dynamic>>())
      if (e['lat'] != null && e['lon'] != null)
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [e['lon'], e['lat']],
          },
          'properties': {
            'name': ((e['tags'] as Map?)?['name'] ??
                    (e['tags'] as Map?)?['ref'] ??
                    '')
                .toString(),
          },
        },
  ];
  stdout.writeln('entrances ${features.length}');

  Directory('assets').createSync(recursive: true);
  final json = jsonEncode({'type': 'FeatureCollection', 'features': features});
  File(assetPath).writeAsBytesSync(gzip.encode(utf8.encode(json)));
  stdout.writeln('wrote $assetPath '
      '${(File(assetPath).lengthSync() / 1e3).toStringAsFixed(1)} kB');
}

Future<String?> _post(String query) async {
  final c = http.Client();
  try {
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
        if (r.statusCode == 200) return r.body;
        stdout.writeln('  HTTP ${r.statusCode} from $endpoint');
      } catch (e) {
        stdout.writeln('  $endpoint failed: $e');
      }
      await Future<void>.delayed(const Duration(seconds: 10));
    }
  } finally {
    c.close();
  }
  return null;
}
