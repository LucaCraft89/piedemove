/// Focus filters the live vehicles by route, generally; clearing restores all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/ui/map/map_focus.dart';
import 'package:piedemove/ui/map/vehicle_features.dart';

import 'support/synthetic.dart';

RtVehicle _v(String id, String route) => RtVehicle(
    id: id, label: id, tripId: null, routeId: route, lat: 45, lon: 7.6,
    bearing: null, stopSequence: null, stopId: null,
    status: VehicleStatus.inTransitTo, timestamp: null);

void main() {
  test('only focused route vehicles; null focus keeps all', () {
    final ix = syntheticIndex(
      stops: [('A', 'A', 45.0, 7.6), ('B', 'B', 45.01, 7.6)],
      patterns: [
        ('33', RouteType.bus, ['A', 'B'], [[0, 60]]),
        ('42', RouteType.bus, ['A', 'B'], [[0, 60]]),
      ],
    );
    final vs = [_v('a', ix.routeIds[0]), _v('b', ix.routeIds[1]), _v('c', 'zz')];
    expect(vehiclesForRoutes(ix, vs, null).length, 3);
    expect(focusRoutes(ix, null), isNull);
    final f = focusRoutes(ix, const RouteFocus(0));
    expect(vehiclesForRoutes(ix, vs, f).map((v) => v.id), ['a']);
  });
}
