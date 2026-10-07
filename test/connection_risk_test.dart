// "Coincidenza a rischio": seen from the bus when the live delay makes the
// change ahead impossible.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/trip/live_stats.dart';

import 'support/synthetic.dart';

const _lat = 45.07, _lon0 = 7.660, _step = 0.002;
const _h8 = 8 * 3600;

void main() {
  final date = syntheticDate();
  DateTime at(int h, int m) => DateTime(date.year, date.month, date.day, h, m);

  // Line 2 s0 -> s1 (08:00, 08:15), line 4 s1 -> s2 (08:05, 08:20).
  final ix = syntheticIndex(
    stops: [
      for (var i = 0; i < 3; i++) ('s$i', 'Fermata $i', _lat, _lon0 + i * _step),
    ],
    patterns: [
      ('2', RouteType.bus, ['s0', 's1'], [
        [_h8, _h8 + 120],
        [_h8 + 900, _h8 + 1020],
      ]),
      ('4', RouteType.tram, ['s1', 's2'], [
        [_h8 + 300, _h8 + 420],
        [_h8 + 1200, _h8 + 1320],
      ]),
    ],
  );
  final run2 = ix.patternTripAt(0, 0), run4 = ix.patternTripAt(1, 0);
  final journey = Journey([
    Leg(
      kind: LegKind.ride,
      fromStop: 0,
      toStop: 1,
      departure: _h8,
      arrival: _h8 + 120,
      options: [
        RideOption(routeShortName: '2', routeType: RouteType.bus, pattern: 0,
            trip: run2, departure: _h8, arrival: _h8 + 120),
      ],
    ),
    Leg(
      kind: LegKind.ride,
      fromStop: 1,
      toStop: 2,
      departure: _h8 + 300,
      arrival: _h8 + 420,
      options: [
        RideOption(routeShortName: '4', routeType: RouteType.tram, pattern: 1,
            trip: run4, departure: _h8 + 300, arrival: _h8 + 420),
      ],
    ),
  ], date);
  final route = buildLiveRoute(ix, null, journey,
      originLat: _lat, originLon: _lon0, destLat: _lat, destLon: _lon0 + 2 * _step);
  final riding = LiveTripState(
    route: route,
    journey: journey,
    metresToEnd: route.legs.first.metres,
    legStartedAt: at(8, 0),
  );

  test('on time: no risk', () {
    expect(connectionRisk(riding, ix, now: at(8, 1)), isNull);
  });

  test('the bus 4 min late: the change is gone, the next one is named', () {
    int? late(int trip, int pos) => trip == run2 && pos == 1 ? 240 : null;
    final r = connectionRisk(riding, ix, now: at(8, 1), delays: late)!;
    expect(r.lines, '4');
    expect(r.ready, at(8, 6));
    expect(r.planned, at(8, 5));
    expect(r.next?.time, at(8, 20));
    expect(connectionRiskLabel(r),
        'Il 4 delle 08:05 parte prima che arrivi (08:06) · il prossimo 08:20');
  });

  test('the tram late too: no risk after all', () {
    int? both(int trip, int pos) =>
        trip == run2 && pos == 1 ? 240 : trip == run4 && pos == 0 ? 120 : null;
    expect(connectionRisk(riding, ix, now: at(8, 1), delays: both), isNull);
  });

  test('walking or on the last ride: nothing to say', () {
    expect(connectionRisk(nextLeg(riding), ix, now: at(8, 6)), isNull);
  });
}
