// "I tuoi viaggi": walking spared, this month and in all.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/location/trip_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

TripRecord _trip(DateTime at, double walk, double direct, {double ride = 3000}) =>
    TripRecord(
        at: at,
        walkMetres: walk,
        rideMetres: ride,
        directWalkMetres: direct,
        seconds: 1500);

void main() {
  final now = DateTime(2026, 10, 7, 12);

  test('spared is never negative; totals per month and in all', () {
    expect(_trip(now, 500, 3000).spared, 2500);
    expect(_trip(now, 900, 600).spared, 0);
    final (month, all) = monthAndAll([
      _trip(DateTime(2026, 9, 30), 400, 2400),
      _trip(DateTime(2026, 10, 2), 300, 3300),
      _trip(DateTime(2026, 10, 6), 200, 1200),
    ], now);
    expect(month.trips, 2);
    expect(month.walk, 500);
    expect(month.spared, 4000);
    expect(all.trips, 3);
    expect(all.ride, 9000);
  });

  test('kept between runs, as JSON', () async {
    SharedPreferences.setMockInitialValues({});
    final h = TripHistory();
    await h.add(_trip(now, 420, 3100));
    final again = TripHistory();
    await Future<void>.delayed(Duration.zero);
    await pumpEventQueue();
    expect(again.state.single.walkMetres, 420);
    expect(again.state.single.at, now);
    await again.clear();
    expect(again.state, isEmpty);
  });
}
