/// Walk legs (phase 5): one feature per walk leg, access/egress included (the
/// bug was that the off-stop ends were never resolved), straight fallback
/// marked approximate, and a disk-cached solved path served offline.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/walk_path.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/map/line_features.dart';
import 'package:piedemove/ui/map/map_style.dart';

import 'support/synthetic.dart';

void main() {
  final ix = syntheticIndex(
    stops: [('A', 'A', 45.0, 7.6), ('B', 'B', 45.01, 7.6), ('C', 'C', 45.02, 7.6)],
    patterns: [('9', RouteType.bus, ['A', 'B'], [[0, 60]])],
  );
  Leg walk(int from, int to, double m) => Leg(
      kind: LegKind.walk, fromStop: from, toStop: to, departure: 0, arrival: 60, walkMetres: m);
  final journey = Journey([
    walk(-1, 0, 120),
    Leg(kind: LegKind.ride, fromStop: 0, toStop: 1, departure: 60, arrival: 600),
    walk(1, 2, 90),
    walk(2, -1, 300),
  ], DateTime(2026, 9, 24));

  test('access, transfer and egress each emit a feature; ends come from the query', () {
    final fc = walkFeatures(ix, journey,
        path: (_) => null,
        originLat: 44.999, originLon: 7.599, destLat: 45.021, destLon: 7.601);
    final f = fc['features'] as List;
    expect(f.length, 3);
    expect(f.every((x) => x['properties']['approx'] == 1), isTrue);
    expect(f.first['geometry']['coordinates'].first, [7.599, 44.999]);
    expect(f.last['geometry']['coordinates'].last, [7.601, 45.021]);
  });

  test('without origin/destination the off-stop legs are skipped, not crashed', () {
    final fc = walkFeatures(ix, journey, path: (_) => null);
    expect((fc['features'] as List).length, 1);
  });

  test('solved path is not approx and dash spacing is shared', () {
    final fc = walkFeatures(ix, journey,
        path: (i) => i == 2 ? [[7.6, 45.01], [7.61, 45.015], [7.6, 45.02]] : null,
        originLat: 44.999, originLon: 7.599, destLat: 45.021, destLon: 7.601);
    final byApprox = [for (final x in fc['features']) x['properties']['approx']];
    expect(byApprox, [1, 0, 1]);
    final a = walkDash(walkWidth), b = walkDash(walkWidth + walkCasingExtra);
    expect((a[0] + a[1]) * walkWidth,
        closeTo((b[0] + b[1]) * (walkWidth + walkCasingExtra), 1e-9));
  });

  test('walkPath: failure -> null (never throws), success cached on disk', () async {
    final dir = Directory.systemTemp.createTempSync('walk');
    final down = MockClient((_) async => throw const SocketException('offline'));
    expect(await walkPath(45.0, 7.6, 45.001, 7.6, client: down, cacheDir: dir), isNull);

    const way = {
      'elements': [
        {
          'type': 'way', 'id': 1,
          'tags': {'highway': 'footway'},
          'nodes': [1, 2],
          'geometry': [
            {'lat': 45.1, 'lon': 7.7},
            {'lat': 45.101, 'lon': 7.7},
          ],
        }
      ]
    };
    var calls = 0;
    final up = MockClient((_) async {
      calls++;
      return http.Response(jsonEncode(way), 200);
    });
    final p = await walkPath(45.1, 7.7, 45.101, 7.7, client: up, cacheDir: dir);
    expect(p, isNotNull);
    expect(calls, 1);
    expect(dir.listSync(), isNotEmpty);
    expect(await walkPath(45.1, 7.7, 45.101, 7.7, client: down, cacheDir: dir), p);
  });
}
