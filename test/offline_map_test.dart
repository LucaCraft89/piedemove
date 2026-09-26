// The offline basemap area: the GTT network's extent, and a tile budget.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/offline_map.dart';

import 'support/synthetic.dart';

void main() {
  test('area: live network stops only, padded; regional ones do not stretch it',
      () {
    final ix = syntheticIndex(
      stops: [
        ('A', 'A', 45.00, 7.60),
        ('B', 'B', 45.10, 7.75),
        ('R', 'R', 44.40, 8.60), // a regional-only stop far away
      ],
      patterns: [
        ('4', RouteType.tram, ['A', 'B'], [[0, 600]]),
        ('X', RouteType.bus, ['A', 'R'], [[0, 3600]]),
      ],
      regionalPatterns: {1},
    );
    final a = offlineArea(ix)!;
    expect(a.south, closeTo(44.99, 1e-9));
    expect(a.north, closeTo(45.11, 1e-9));
    expect(a.west, closeTo(7.59, 1e-9));
    expect(a.east, closeTo(7.76, 1e-9));
  });

  test('tile count grows ~4x per zoom; the top zoom keeps within budget', () {
    const turin = (south: 44.99, west: 7.55, north: 45.15, east: 7.80);
    final z13 = tileCount(turin, 13, 13), z14 = tileCount(turin, 14, 14);
    expect(z14, inInclusiveRange(z13 * 3, z13 * 5));
    expect(offlineTopZoom(turin), offlineMaxZoom, reason: 'a city fits at z14');
    const piemonte = (south: 44.0, west: 6.6, north: 46.5, east: 9.2);
    final top = offlineTopZoom(piemonte);
    expect(top, lessThan(offlineMaxZoom));
    expect(tileCount(piemonte, offlineMinZoom, top),
        lessThanOrEqualTo(offlineMaxTiles),
        reason: 'unless it bottoms out at z12');
  });
}
