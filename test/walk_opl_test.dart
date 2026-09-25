import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/geo/walk_build.dart';

/// The inverse of what `osmium cat -f opl` writes, from Overpass JSON.
List<String> _toOpl(Map<String, dynamic> json) => [
      for (final e in json['elements'] as List)
        () {
          final tags = (e['tags'] as Map?)?.entries
              .map((t) => '${t.key}=${t.value.toString().replaceAll(',', '%2c%').replaceAll(' ', '%20%')}')
              .join(',');
          final t = tags == null ? '' : ' T$tags';
          return e['type'] == 'node'
              ? 'n${e['id']} v1 t2026-01-01T00:00:00Z$t x${e['lon']} y${e['lat']}'
              : 'w${e['id']} v1 t2026-01-01T00:00:00Z$t N${(e['nodes'] as List).map((n) => 'n$n').join(',')}';
        }()
    ];

void main() {
  test('OPL input yields the same OsmData as the Overpass JSON', () {
    final dir = Directory('build/walk_osm');
    // A cached Overpass tile when one exists, else the inline fixture.
    final tile = (dir.existsSync() ? dir.listSync() : const <FileSystemEntity>[])
        .whereType<File>()
        .where((f) => f.path.endsWith('.json.gz'))
        .toList();
    final json = tile.isEmpty
        ? {
            'elements': [
              {'type': 'node', 'id': 1, 'lat': 45.0, 'lon': 7.6, 'tags': {'highway': 'crossing'}},
              {'type': 'node', 'id': 2, 'lat': 45.001, 'lon': 7.6},
              {'type': 'way', 'id': 9, 'nodes': [1, 2], 'tags': {'highway': 'footway', 'name': 'a, b'}},
            ]
          }
        : jsonDecode(utf8.decode(gzip.decode(tile.first.readAsBytesSync()))) as Map<String, dynamic>;
    final a = OsmData()..addOverpass(json);
    final b = OsmData()..addOverpass(oplToOverpass(_toOpl(json)));
    expect(b.nodes.length, a.nodes.length);
    expect(b.ways.length, a.ways.length);
    expect(b.ways.values.map((w) => '${w.id}${w.nodes}${w.tags}').toList(),
        a.ways.values.map((w) => '${w.id}${w.nodes}${w.tags}').toList());
    expect(b.timestamp, DateTime.utc(2026).millisecondsSinceEpoch ~/ 1000);
  });
}
