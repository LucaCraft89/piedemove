// The end of a live trip: a summary instead of the strip just vanishing.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/location/trip_summary.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/theme/app_theme.dart';
import 'package:piedemove/ui/trip/arrival_sheet.dart';

import 'support/synthetic.dart';

const _lat = 45.07, _lon0 = 7.660, _step = 0.002;

class _Live extends LiveTripController {
  _Live(super.ref, LiveTripState s) {
    state = s;
  }
}

void main() {
  final day = DateTime(2026, 9, 19);
  final ix = syntheticIndex(
    stops: [
      for (var i = 0; i < 4; i++)
        ('s$i', 'Fermata $i', _lat, _lon0 + i * _step),
    ],
    patterns: [
      ('2', RouteType.bus, ['s0', 's1', 's2', 's3'], [
        [36000, 36120, 36240, 36360],
      ]),
      ('4', RouteType.tram, ['s0', 's3'], [
        [36000, 36360],
      ]),
    ],
  );
  final journey = Journey([
    const Leg(
      kind: LegKind.walk,
      fromStop: -1,
      toStop: 0,
      departure: 35880,
      arrival: 35940,
      walkMetres: 80,
    ),
    const Leg(
      kind: LegKind.ride,
      fromStop: 0,
      toStop: 3,
      departure: 36000,
      arrival: 36360, // 10:06
      options: [
        RideOption(routeShortName: '2', routeType: RouteType.bus, pattern: 0,
            trip: 0, departure: 36000, arrival: 36360),
        RideOption(routeShortName: '4', routeType: RouteType.tram, pattern: 1,
            trip: 1, departure: 36000, arrival: 36360),
      ],
    ),
  ], day);
  final route = buildLiveRoute(ix, null, journey,
      originLat: _lat, originLon: _lon0 - 0.001);
  final walking = LiveTripState(
      route: route, journey: journey, metresToEnd: route.legs[0].metres);

  test('the summary: plan against arrival, walking, lines', () {
    final s = tripSummary(walking,
        startedAt: DateTime(2026, 9, 19, 9, 57),
        arrivedAt: DateTime(2026, 9, 19, 10, 9),
        destination: 'Via Cristalliera');
    expect(s.duration, const Duration(minutes: 12));
    expect(s.plannedArrival, DateTime(2026, 9, 19, 10, 6));
    expect(s.minutesLate, 3);
    expect(s.walkMetres, closeTo(route.legs[0].metres, 0.1));
    expect(s.rides, [
      [('2', RouteType.bus), ('4', RouteType.tram)],
    ]);
    expect(s.transfers, 0);
    expect(s.rideMetres, greaterThan(0));
    expect(s.directWalkMetres, greaterThan(s.walkMetres),
        reason: 'walking the whole way is longer than the walk to the stop');
    expect(punctualityLabel(0), 'in orario');
    expect(punctualityLabel(-2), '2 min in anticipo');
    expect(punctualityLabel(3), '3 min di ritardo');
  });

  Future<ProviderContainer> pump(WidgetTester t, LiveTripState s) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3; // a 360 dp wide phone
    addTearDown(t.view.reset);
    final c = ProviderContainer(overrides: [
      transitIndexProvider.overrideWith((ref) async => ix),
      liveTripProvider.overrideWith((ref) => _Live(ref, s)),
    ]);
    addTearDown(c.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(body: Stack(children: [ArrivalSheet()])),
      ),
    ));
    return c;
  }

  testWidgets('"Sono arrivato" on the last leg shows the summary', (t) async {
    final c = await pump(t, nextLeg(walking, at: day));
    expect(find.text('Sei arrivato'), findsNothing);
    c.read(liveTripProvider.notifier).manualAdvance();
    await t.pump();
    expect(c.read(liveTripProvider), isNull, reason: 'the trip has stopped');
    expect(find.text('Sei arrivato'), findsOneWidget);
    expect(find.text('diretto'), findsOneWidget);
    expect(find.text('2 · 4'), findsNothing, reason: 'bus and tram: two segments');
    expect(find.text('2'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(t.takeException(), isNull);

    await t.tap(find.text('Fine'));
    await t.pump();
    expect(c.read(tripSummaryProvider), isNull);
    expect(find.text('Sei arrivato'), findsNothing);
  });
}
