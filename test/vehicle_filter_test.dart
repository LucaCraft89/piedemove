/// Focus filters the live vehicles by route, generally; clearing restores all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/routing/journey.dart';
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

  vehicleDirectionTests();
}

RtVehicle _at(String id, String route, double lat, double lon, double? bearing) =>
    RtVehicle(
        id: id, label: id, tripId: null, routeId: route, lat: lat, lon: lon,
        bearing: bearing, stopSequence: null, stopId: null,
        status: VehicleStatus.inTransitTo, timestamp: null);

void vehicleDirectionTests() {
  // Line 9 runs east along a street: A -> B -> C.
  final ix = syntheticIndex(
    stops: [
      ('A', 'A', 45.0, 7.600),
      ('B', 'B', 45.0, 7.605),
      ('C', 'C', 45.0, 7.610),
      ('Z', 'Z', 45.1, 7.600),
    ],
    patterns: [
      ('9', RouteType.bus, ['A', 'B', 'C'], [[0, 60, 120]]),
      ('4', RouteType.tram, ['A', 'Z'], [[0, 600]]),
    ],
  );
  final journey = Journey([
    const Leg(
      kind: LegKind.ride,
      fromStop: 0,
      toStop: 2,
      departure: 0,
      arrival: 120,
      options: [
        RideOption(routeShortName: '9', routeType: RouteType.bus, pattern: 0,
            trip: 0, departure: 0, arrival: 120),
      ],
    ),
  ], DateTime(2026, 9, 19));
  final r9 = ix.routeIds[0];

  test('a trip shows its line heading its way only', () {
    final vs = [
      _at('east', r9, 45.0001, 7.603, 88), // the rider's bus
      _at('west', r9, 45.0001, 7.603, 272), // same street, other way
      _at('nobearing', r9, 45.0001, 7.606, null), // unknown: kept
      _at('depot', r9, 45.05, 7.603, 90), // far off the pattern
      _at('tram', ix.routeIds[1], 45.0001, 7.603, 90), // another line
    ];
    expect(vehiclesForJourney(ix, null, vs, journey).map((v) => v.id),
        ['east', 'nobearing']);
  });

  test('heading tolerance: a bend is still the same way', () {
    expect(headingMatchesPattern(ix, null, 0, 45.0, 7.602, 140), isTrue);
    expect(headingMatchesPattern(ix, null, 0, 45.0, 7.602, 190), isFalse);
  });
}
