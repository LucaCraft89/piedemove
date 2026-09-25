// The live strip renders at a glance on a phone-width screen, in every
// phase: walking, waiting at the stop, riding - no overflow, no exception.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/theme/app_theme.dart';
import 'package:piedemove/ui/trip/live_strip.dart';

import 'support/synthetic.dart';

const _lat = 45.07, _lon0 = 7.660, _step = 0.002;

class _Live extends LiveTripController {
  _Live(super.ref, LiveTripState s) {
    state = s;
  }
}

void main() {
  final now = DateTime.now();
  final secs = now.hour * 3600 + now.minute * 60 + 240; // a bus in ~4 min
  final ix = syntheticIndex(
    stops: [
      for (var i = 0; i < 4; i++)
        ('s$i', 'Fermata $i', _lat, _lon0 + i * _step),
    ],
    patterns: [
      ('2', RouteType.bus, ['s0', 's1', 's2', 's3'], [
        [secs, secs + 120, secs + 240, secs + 360],
      ]),
    ],
    serviceStartDay: TransitIndex.epochDay(now) - 1,
  );
  final journey = Journey([
    Leg(
      kind: LegKind.walk,
      fromStop: -1,
      toStop: 0,
      departure: secs - 120,
      arrival: secs - 60,
      walkMetres: 80,
    ),
    Leg(
      kind: LegKind.ride,
      fromStop: 0,
      toStop: 3,
      departure: secs,
      arrival: secs + 360,
      options: [
        RideOption(
          routeShortName: '2',
          routeType: RouteType.bus,
          pattern: 0,
          trip: 0,
          departure: secs,
          arrival: secs + 360,
        ),
      ],
    ),
  ], DateTime(now.year, now.month, now.day));
  final route = buildLiveRoute(ix, null, journey,
      originLat: _lat, originLon: _lon0 - 0.001);
  final walking = LiveTripState(
      route: route, journey: journey, metresToEnd: route.legs[0].metres);

  Future<void> pump(WidgetTester t, LiveTripState s) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3; // a 360 dp wide phone
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [
        transitIndexProvider.overrideWith((ref) async => ix),
        delayLookupProvider.overrideWith((ref) => (trip, pos) => 120),
        unavailableLookupProvider.overrideWith((ref) => null),
        liveTripProvider.overrideWith((ref) => _Live(ref, s)),
      ],
      child: MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(body: Stack(children: [LiveStrip()])),
      ),
    ));
    await t.pump();
  }

  testWidgets('walking to the stop: countdown to the bus', (t) async {
    await pump(t, walking);
    expect(find.text('min'), findsOneWidget);
    expect(find.textContaining('+2 min'), findsOneWidget);
    expect(find.text('Sono salito'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('waiting at the stop', (t) async {
    await pump(t, walking.copyWith(reachedBoardStop: true));
    expect(find.textContaining('Aspetta il 2'), findsOneWidget);
    expect(find.text('alla fermata Fermata 0'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('riding: stops left, big', (t) async {
    await pump(
        t,
        nextLeg(walking, at: now).copyWith(stopsRemaining: 3));
    expect(find.text('3'), findsOneWidget);
    expect(find.text('fermate'), findsOneWidget);
    expect(find.text('Sono sceso'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
