// The live strip's numbers follow the live departures at the stop and the run
// actually boarded - not the one run the planner picked (rider report, beta 6:
// "the bus timing does not update live").
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/trip/live_stats.dart';
import 'package:piedemove/ui/trip/live_strip.dart' show waitingLabel;

import 'support/synthetic.dart';

const _lat = 45.07, _lon0 = 7.660, _step = 0.002;
const _h8 = 8 * 3600;

final _date = syntheticDate();
DateTime _at(int h, int m, [int s = 0]) =>
    DateTime(_date.year, _date.month, _date.day, h, m, s);

// Line 2 s0 -> s3, runs at 08:00 and 08:15; 6 min end to end.
final _ix = syntheticIndex(
  stops: [
    for (var i = 0; i < 4; i++) ('s$i', 'Fermata $i', _lat, _lon0 + i * _step),
  ],
  patterns: [
    ('2', RouteType.bus, ['s0', 's1', 's2', 's3'], [
      [_h8, _h8 + 120, _h8 + 240, _h8 + 360],
      [_h8 + 900, _h8 + 1020, _h8 + 1140, _h8 + 1260],
    ]),
  ],
);

final _journey = Journey([
  const Leg(
    kind: LegKind.walk,
    fromStop: -1,
    toStop: 0,
    departure: _h8 - 120,
    arrival: _h8 - 60,
    walkMetres: 80,
  ),
  const Leg(
    kind: LegKind.ride,
    fromStop: 0,
    toStop: 3,
    departure: _h8,
    arrival: _h8 + 360,
    options: [
      RideOption(
        routeShortName: '2',
        routeType: RouteType.bus,
        pattern: 0,
        trip: 0,
        departure: _h8,
        arrival: _h8 + 360,
      ),
    ],
  ),
], _date);

LiveTripState _state({int leg = 0, double along = 0, DateTime? started}) {
  final route = buildLiveRoute(_ix, null, _journey,
      originLat: _lat, originLon: _lon0 - 0.001);
  return LiveTripState(
      route: route,
      journey: _journey,
      legIndex: leg,
      along: along,
      legStartedAt: started);
}

void main() {
  test('walking to the stop: next bus and the one after, timetable', () {
    final st = liveStats(_state(), _ix, now: _at(7, 58));
    expect(st.next!.routeShortName, '2');
    expect(st.next!.time, _at(8, 0));
    expect(st.next!.live, isFalse);
    expect(st.then!.time, _at(8, 15));
    expect(st.arrival, _at(8, 6));
    expect(st.arrivalLive, isFalse);
  });

  test('a live delay moves the countdown, and the arrival with it', () {
    final st = liveStats(_state(), _ix,
        now: _at(7, 58), delays: (trip, pos) => trip == 0 ? 180 : null);
    expect(st.next!.time, _at(8, 3));
    expect(st.next!.delaySeconds, 180);
    expect(st.arrival, _at(8, 9));
    expect(st.arrivalLive, isTrue);
  });

  test('the planned bus gone: the countdown rolls to the next one', () {
    final st = liveStats(_state(), _ix, now: _at(8, 2));
    expect(st.next!.time, _at(8, 15));
    expect(st.then, isNull);
    expect(st.arrival, _at(8, 21), reason: 'follows the bus now coming');
  });

  test('on board: the run actually boarded, not the planned one', () {
    final st = liveStats(_state(leg: 1, along: 100, started: _at(8, 15, 20)),
        _ix,
        now: _at(8, 17), delays: (trip, pos) => trip == 1 ? 60 : null);
    expect(st.alightAt, _at(8, 22));
    expect(st.alightDelay, 60);
    expect(st.arrival, _at(8, 22));
    expect(st.next, isNull);
    expect(st.metresLeft,
        closeTo(_state(leg: 1).route.legs[1].cumulative.last - 100, 0.1));
  });

  test('at the stop the strip names the bus coming', () {
    final waiting = _state().copyWith(reachedBoardStop: true);
    expect(waitingLabel(_state(), _ix), isNull, reason: 'not at the stop yet');
    expect(waitingLabel(waiting, _ix), 'Aspetta il 2 per Fermata 3');
    expect(waitingLabel(_state(leg: 1), _ix), isNull, reason: 'aboard');
  });

  test('labels', () {
    final now = _at(8, 0);
    expect(minutesUntil(now.add(const Duration(minutes: 4)), now), 4);
    expect(minutesUntil(now.add(const Duration(seconds: 20)), now), 0);
    expect(untilLabel(now.add(const Duration(minutes: 4)), now), 'tra 4 min');
    expect(untilLabel(now.subtract(const Duration(minutes: 2)), now), 'passato');
    expect(delayLabel(null), isNull);
    expect(delayLabel(20), 'in orario');
    expect(delayLabel(180), '+3 min');
  });
}
