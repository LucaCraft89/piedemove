// The live strip's numbers: next vehicle, alight time, trip arrival, time and
// distance left - timetable, then moved by live delays.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/trip/live_stats.dart';
import 'package:piedemove/ui/trip/live_strip.dart' show waitingLabel;

import 'support/synthetic.dart';

const _lat = 45.07, _lon0 = 7.660, _step = 0.002;
const _day = 8 * 3600;

final _ix = syntheticIndex(
  stops: [
    for (var i = 0; i < 4; i++) ('s$i', 'Fermata $i', _lat, _lon0 + i * _step),
  ],
  patterns: [
    ('2', RouteType.bus, ['s0', 's1', 's2', 's3'], [
      [_day, _day + 120, _day + 240, _day + 360],
    ]),
  ],
);

final _journey = Journey([
  const Leg(
    kind: LegKind.walk,
    fromStop: -1,
    toStop: 0,
    departure: _day - 120,
    arrival: _day - 60,
    walkMetres: 80,
  ),
  const Leg(
    kind: LegKind.ride,
    fromStop: 0,
    toStop: 3,
    departure: _day,
    arrival: _day + 360,
    options: [
      RideOption(
        routeShortName: '2',
        routeType: RouteType.bus,
        pattern: 0,
        trip: 0,
        departure: _day,
        arrival: _day + 360,
      ),
    ],
  ),
], DateTime(2026, 9, 19));

LiveTripState _state({int leg = 0, double along = 0}) {
  final route = buildLiveRoute(_ix, null, _journey,
      originLat: _lat, originLon: _lon0 - 0.001);
  return LiveTripState(
      route: route, journey: _journey, legIndex: leg, along: along);
}

void main() {
  test('walking to the stop: the next bus, timetable only', () {
    final s = _state();
    final st = liveStats(s, delayOf: (_, {atAlight = false}) => null);
    expect(st.nextLine, '2');
    expect(st.nextDeparture, DateTime(2026, 9, 19, 8));
    expect(st.nextDelay, isNull);
    expect(st.alightAt, isNull);
    expect(st.arrival, DateTime(2026, 9, 19, 8, 6));
    expect(st.arrivalDelayKnown, isFalse);
    final total = s.route.legs[0].cumulative.last + s.route.legs[1].cumulative.last;
    expect(st.metresLeft, closeTo(total, 0.1));
  });

  test('live delay moves the bus, the alight time and the arrival', () {
    final s = _state(leg: 1, along: 100);
    final st = liveStats(s,
        delayOf: (i, {atAlight = false}) => i == 1 ? 180 : null);
    expect(st.alightAt, DateTime(2026, 9, 19, 8, 9));
    expect(st.alightDelay, 180);
    expect(st.arrival, DateTime(2026, 9, 19, 8, 9));
    expect(st.arrivalDelayKnown, isTrue);
    expect(st.nextDeparture, isNull, reason: 'already on board');
    expect(st.metresLeft,
        closeTo(s.route.legs[1].cumulative.last - 100, 0.1));
  });

  test('legDelay reads the board and alight positions of the run', () {
    int? lookup(int trip, int pos) => pos * 60;
    final ride = _journey.legs[1];
    expect(legDelay(_ix, lookup, ride), 0);
    expect(legDelay(_ix, lookup, ride, atAlight: true), 180);
    expect(legDelay(_ix, null, ride), isNull);
    expect(legDelay(_ix, lookup, _journey.legs[0]), isNull, reason: 'walk');
  });

  test('labels', () {
    final now = DateTime(2026, 9, 19, 8);
    expect(untilLabel(now.add(const Duration(minutes: 4)), now), 'tra 4 min');
    expect(untilLabel(now.add(const Duration(seconds: 20)), now), 'ora');
    expect(untilLabel(now.subtract(const Duration(minutes: 2)), now), 'passato');
    expect(untilLabel(now.add(const Duration(minutes: 65)), now), 'tra 1 h 05');
    expect(delayLabel(null), isNull);
    expect(delayLabel(20), 'in orario');
    expect(delayLabel(180), '+3 min');
    expect(delayLabel(-60), '-1 min');
  });

  test('at the boarding stop the strip says which bus to wait for', () {
    final walking = _state();
    expect(waitingLabel(walking, _ix), isNull, reason: 'not at the stop yet');
    final waiting = walking.copyWith(reachedBoardStop: true);
    expect(waitingLabel(waiting, _ix), 'Aspetta il 2 per Fermata 3');
    expect(waitingLabel(_state(leg: 1), _ix), isNull, reason: 'aboard');
  });
}
