// "Where is my bus": matched by line, heading and place on the route.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/location/bus_match.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/trip/live_strip.dart' show busLabel;

import 'support/synthetic.dart';

// Line 10 east along a street: s0 .. s5, ~157 m apart; the rider boards at s4.
const _lat = 45.07, _lon0 = 7.660, _step = 0.002;

RtVehicle _bus(String id, String route, double lon, double? bearing,
        {double lat = _lat}) =>
    RtVehicle(
        id: id, label: id, tripId: null, routeId: route, lat: lat, lon: lon,
        bearing: bearing, stopSequence: null, stopId: null,
        status: VehicleStatus.inTransitTo, timestamp: null);

void main() {
  final ix = syntheticIndex(
    stops: [
      for (var i = 0; i < 6; i++) ('s$i', 'S$i', _lat, _lon0 + i * _step),
    ],
    patterns: [
      ('10', RouteType.bus, [for (var i = 0; i < 6; i++) 's$i'], [
        [0, 60, 120, 180, 240, 300],
      ]),
      ('4', RouteType.tram, ['s0', 's5'], [[0, 300]]),
    ],
  );
  const ride = Leg(
    kind: LegKind.ride,
    fromStop: 4,
    toStop: 5,
    departure: 240,
    arrival: 300,
    options: [
      RideOption(routeShortName: '10', routeType: RouteType.bus, pattern: 0,
          trip: 0, departure: 240, arrival: 300),
    ],
  );
  final r10 = ix.routeIds[0];

  test('the nearest bus still coming, heading our way', () {
    final b = approachingBus(ix, [
      _bus('far', r10, _lon0 + 0.5 * _step, 90), // between s0 and s1
      _bus('near', r10, _lon0 + 2.5 * _step, 88), // between s2 and s3
      _bus('back', r10, _lon0 + 3.5 * _step, 270), // other direction
      _bus('past', r10, _lon0 + 4.6 * _step, 90), // already past s4
      _bus('tram', ix.routeIds[1], _lon0 + 3.5 * _step, 90), // other line
    ], ride)!;
    expect(b.vehicle.id, 'near');
    expect(b.stopsAway, 1, reason: 's3 before ours');
    expect(b.metresAway, closeTo(1.5 * 157, 10));
    expect(busLabel(b), startsWith('Il 10 è a 2 fermate'));
  });

  test('arriving: next stop is ours and close', () {
    final b = approachingBus(ix, [_bus('a', r10, _lon0 + 3.6 * _step, 90)], ride)!;
    expect(b.stopsAway, 0);
    expect(busLabel(b), 'Il 10 sta arrivando');
  });

  test('none coming: null; off the street: ignored', () {
    expect(approachingBus(ix, const [], ride), isNull);
    expect(
        approachingBus(
            ix, [_bus('x', r10, _lon0 + 2 * _step, 90, lat: _lat + 0.01)], ride),
        isNull);
  });

  test('on board: the line\'s vehicle next to the rider, our way', () {
    final vs = [
      _bus('mine', r10, _lon0 + 4.2 * _step, 91),
      _bus('opposite', r10, _lon0 + 4.21 * _step, 271),
    ];
    expect(riderVehicle(ix, vs, ride, _lat, _lon0 + 4.2 * _step)!.id, 'mine');
    expect(riderVehicle(ix, vs, ride, _lat + 0.01, _lon0), isNull,
        reason: 'nothing within reach of the rider');
  });
}
