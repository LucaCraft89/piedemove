/// A tapped ambient feature names a route by short name; repeated names must
/// resolve to the mode drawn (and to a GTT route, which has geometry).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/ui/map/line_features.dart';

import 'support/synthetic.dart';

void main() {
  test('same short name: the tapped mode wins', () {
    final ix = syntheticIndex(
      stops: [('A', 'A', 45.0, 7.6), ('B', 'B', 45.01, 7.6)],
      patterns: [
        ('4', RouteType.bus, ['A', 'B'], [[0, 60]]),
        ('4', RouteType.tram, ['A', 'B'], [[0, 60]]),
      ],
    );
    final tram = routeForTap(ix, '4', 'tram')!;
    final bus = routeForTap(ix, '4', 'bus')!;
    expect(ix.routeTypes[tram], RouteType.tram);
    expect(ix.routeTypes[bus], RouteType.bus);
    expect(routeForTap(ix, 'nope', 'bus'), isNull);
  });
}
