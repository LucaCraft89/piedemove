import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/geo/osm_opl.dart';
import 'package:piedemove/geo/road_graph.dart';

void main() {
  const opl = [
    'n1 v1 x7.6 y45.0',
    'w10 v2 dV c1 t2026-09-01T00:00:00Z i1 uA '
        'Thighway=residential,name=Via%20%Roma '
        'Nn1x7.6y45.0,n2x7.601y45.0005,n3x7.602y45.001',
    'w11 v1 dV c1 t2026-09-01T00:00:00Z i1 uA Trailway=tram Nn3x7.602y45.001,n4x7.603y45.002',
    'w12 v1 dV c1 t2026-09-01T00:00:00Z i1 uA Trailway=subway Nn5x7.7y45.1,n6x7.71y45.11',
    'w13 v1 dV c1 t2026-09-01T00:00:00Z i1 uA Tbuilding=yes Nn7x7.5y45.0,n8x7.51y45.0',
    // A node outside the extract has no location: the way is dropped whole.
    'w14 v1 dV c1 t2026-09-01T00:00:00Z i1 uA Thighway=primary Nn9x7.6y45.0,n10',
  ];

  test('roads and tram track become out-geom ways the graph parser reads', () {
    final json = oplWaysToOverpassGeom(opl, isRoadOrTramWay);
    final ways = parseOsmJson(jsonEncode(json));
    expect(ways.map((w) => w.id), [10, 11]);
    final road = ways.first;
    expect(road.tags['name'], 'Via Roma');
    expect(road.lat.length, 3);
    expect(road.lon[2], closeTo(7.602, 1e-9));
  });

  test('the rail file gets metro track only', () {
    final ways = parseOsmJson(jsonEncode(oplWaysToOverpassGeom(opl, isRailWay)));
    expect(ways.map((w) => w.id), [12]);
  });

  test('real osmium output (locations_on_ways) parses; bare ids do not', () {
    // Verbatim from osmium 1.16 `cat -f opl,locations_on_ways=true`.
    const located = [
      r'w10 v2 dV c0 t2026-09-01T00:00:00Z i0 u Thighway=residential,name=Via%20%Roma%2c%%20%1 Nn1x7.6y45,n2x7.601y45.0005,n3x7.602y45.001',
      r'w11 v1 dV c0 t2026-09-01T00:00:00Z i0 u Trailway=subway Nn3x7.602y45.001,n1x7.6y45',
    ];
    final roads = parseOsmJson(jsonEncode(oplWaysToOverpassGeom(located, isRoadOrTramWay)));
    expect(roads.single.tags['name'], 'Via Roma, 1');
    expect(roads.single.lat, [45.0, 45.0005, 45.001]);
    expect(parseOsmJson(jsonEncode(oplWaysToOverpassGeom(located, isRailWay))), hasLength(1));
    // The same ways written without locations_on_ways: nothing usable.
    const bare = [
      r'w10 v2 dV c0 t2026-09-01T00:00:00Z i0 u Thighway=residential Nn1,n2,n3',
    ];
    expect(oplWaysToOverpassGeom(bare, isRoadOrTramWay)['elements'], isEmpty);
  });
}
