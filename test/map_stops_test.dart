import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/ui/map/stop_features.dart';
import 'package:piedemove/ui/sheets/nearby_sheet.dart';

import 'support/synthetic.dart';

/// Two poles ~150 m apart sharing a name, plus one far away: the case the map
/// must never merge into a single dot.
TransitIndex _index() => syntheticIndex(
      stops: [
        ('a', 'Fermata 1 - TRAPANI', 45.0700, 7.6500),
        ('b', 'Fermata 2 - TRAPANI', 45.0700, 7.6519), // ~150 m east of a
        ('c', 'Fermata 3 - LONTANA', 45.1000, 7.7000),
      ],
      patterns: [
        ('2', RouteType.bus, ['a', 'c'], [
          [8 * 3600, 8 * 3600 + 600]
        ]),
        ('13', RouteType.tram, ['a', 'b'], [
          [9 * 3600, 9 * 3600 + 300]
        ]),
      ],
    );

List<Set<int>> _modes(TransitIndex ix) => [
      for (var s = 0; s < ix.stopCount; s++)
        {
          for (var i = ix.stopPatternOffset[s];
              i < ix.stopPatternOffset[s + 1];
              i++)
            ix.routeTypeOfPattern(ix.stopPattern[i]),
        },
    ];

void main() {
  test('every stop is its own feature, with its modes and a clean name', () {
    final ix = _index();
    final fc = stopFeatureCollection(ix, _modes(ix));
    final features = fc['features'] as List;
    expect(features.length, 3);

    final a = features.firstWhere((f) => f['id'] == 0) as Map;
    expect((a['properties'] as Map)['name'], 'TRAPANI');
    // Stop a is served by a bus and a tram: both flags set, tram wins the dot.
    expect((a['properties'] as Map)['b'], 1);
    expect((a['properties'] as Map)['t'], 1);
    expect((a['properties'] as Map)['mode'], 'tram');

    // GeoJSON is lon, lat — in that order.
    final coords = ((a['geometry'] as Map)['coordinates'] as List);
    expect(coords.first, closeTo(7.65, 1e-9));
    expect(coords.last, closeTo(45.07, 1e-9));
  });

  test('a stop no pattern serves is not drawn', () {
    final ix = _index();
    final modes = _modes(ix)..[2] = <int>{};
    final features =
        (stopFeatureCollection(ix, modes)['features'] as List).length;
    expect(features, 2);
  });

  test('each stop carries per-mode flags for cluster aggregation', () {
    final ix = _index();
    final features = stopFeatureCollection(ix, _modes(ix))['features'] as List;
    final props = (features.first as Map)['properties'] as Map;
    // The first pole serves bus 2 and tram 13.
    expect(props['b'], 1);
    expect(props['t'], 1);
    expect(props['m'], 0);
    expect(props['f'], 0);
  });

  test('nearby stops are the ones inside the radius, nearest first', () {
    final ix = _index();
    final near = stopsNear(ix, 45.0700, 7.6500, radius: 400);
    expect(near.map((e) => e.$1), [0, 1]); // the far stop is out
    expect(near.first.$2, lessThan(near.last.$2));
    expect(near.last.$2, closeTo(150, 20));
  });

  test('stopModes reads every route type serving a stop', () {
    final ix = _index();
    expect(_modes(ix)[0], {RouteType.bus, RouteType.tram});
    expect(_modes(ix)[1], {RouteType.tram});
  });
}
