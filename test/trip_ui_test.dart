import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/settings/settings.dart';
import 'package:piedemove/ui/trip/trip_format.dart';
import 'package:piedemove/ui/trip/trip_plan.dart';

Leg _ride({
  required int readyTime,
  required int departure,
  int arrival = 2000,
}) =>
    Leg(
      kind: LegKind.ride,
      fromStop: 1,
      toStop: 2,
      departure: departure,
      arrival: arrival,
      readyTime: readyTime,
      options: [
        RideOption(
          routeShortName: '2',
          routeType: RouteType.tram,
          pattern: 0,
          trip: 0,
          departure: departure,
          arrival: arrival,
        ),
      ],
    );

void main() {
  group('settings', () {
    test('round-trips through JSON', () {
      const settings = PmSettings(
        maxExtraMinutes: 35,
        walkCapMetres: 1200,
        walkSpeed: walkSpeedFast,
        minTransferSeconds: 120,
        modes: {RouteType.tram, RouteType.metro},
        themeMode: ThemeMode.dark,
      );
      final back = PmSettings.fromJson(settings.toJson());
      expect(back.maxExtraMinutes, 35);
      expect(back.walkCapMetres, 1200);
      expect(back.walkSpeed, walkSpeedFast);
      expect(back.minTransferSeconds, 120);
      expect(back.modes, {RouteType.tram, RouteType.metro});
      expect(back.themeMode, ThemeMode.dark);
    });

    test('an unknown or empty shape falls back to working defaults', () {
      final back = PmSettings.fromJson({'modes': const [], 'theme': 'nope'});
      expect(back.modes, PmSettings.allModes);
      expect(back.themeMode, ThemeMode.system);
      expect(back.walkCapMetres, 800);
    });

    test('a speed off the presets counts as custom', () {
      expect(isCustomWalkSpeed(walkSpeedNormal), isFalse);
      expect(isCustomWalkSpeed(walkSpeedFast), isFalse);
      expect(isCustomWalkSpeed(1.4), isTrue);
    });

    test('excluded modes are the complement of the chosen ones', () {
      const settings = PmSettings(modes: {RouteType.bus});
      expect(settings.excludedModes, {
        RouteType.tram,
        RouteType.metro,
        RouteType.funicular,
      });
    });
  });

  group('plan request', () {
    const from = Place(name: 'A', address: '', lat: 45.06, lon: 7.66);
    const to = Place(name: 'B', address: '', lat: 45.07, lon: 7.64);

    test('carries the settings and the arrive-by deadline', () {
      final when = DateTime(2026, 9, 19, 18, 30);
      final request = planRequestFor(
        query: TripQuery(
          from: from,
          to: to,
          whenMode: WhenMode.arriveBy,
          when: when,
        ),
        settings: const PmSettings(
          maxExtraMinutes: 30,
          walkCapMetres: 500,
          modes: {RouteType.bus, RouteType.tram},
        ),
        suspendedStops: const {7},
        detouredRoutes: const {3},
      );
      expect(request.arriveBy, isTrue);
      expect(request.when, when);
      expect(request.walkCapMetres, 500);
      expect(request.maxExtraMinutes, 30);
      expect(request.suspendedStops, {7});
      expect(request.detouredRoutes, {3});
      expect(request.excludedRouteTypes,
          {RouteType.metro, RouteType.funicular});
    });

    test('"now" resolves to the current time, not a stored one', () {
      final request = planRequestFor(
        query: const TripQuery(from: from, to: to),
        settings: const PmSettings(),
        suspendedStops: const {},
        detouredRoutes: const {},
      );
      expect(
        request.when.difference(DateTime.now()).inSeconds.abs(),
        lessThan(5),
      );
    });
  });

  group('formatting', () {
    test('durations read as minutes, then hours', () {
      expect(durationLabel(23 * 60), '23 min');
      expect(durationLabel(65 * 60), '1 h 05');
    });

    test('metres become kilometres only when they stop being readable', () {
      expect(metresLabel(126), '126 m');
      expect(metresLabel(1500), '1.5 km');
    });

    test('the countdown says leaving, left, or now', () {
      final now = DateTime(2026, 9, 19, 18, 0);
      expect(leavesInLabel(now.add(const Duration(minutes: 4)), now),
          'parte tra 4 min');
      expect(leavesInLabel(now.add(const Duration(seconds: 20)), now),
          'parte ora');
      expect(leavesInLabel(now.subtract(const Duration(minutes: 5)), now),
          'partito');
    });

    test('a connection under two minutes is flagged, a comfortable one is not',
        () {
      final tight = Journey([
        _ride(readyTime: 0, departure: 100),
        _ride(readyTime: 1000, departure: 1060),
      ], DateTime(2026, 9, 19));
      final roomy = Journey([
        _ride(readyTime: 0, departure: 100),
        _ride(readyTime: 1000, departure: 1400),
      ], DateTime(2026, 9, 19));
      expect(tightConnection(tight, 1), isTrue);
      expect(tightConnection(roomy, 1), isFalse);
      // The first leg is never a connection: nothing was missed before it.
      expect(tightConnection(tight, 0), isFalse);
    });

    test('a leg keeps every line that can make the hop', () {
      final leg = Leg(
        kind: LegKind.ride,
        fromStop: 1,
        toStop: 2,
        departure: 100,
        arrival: 200,
        options: [
          for (final name in ['33', '42', '68'])
            RideOption(
              routeShortName: name,
              routeType: RouteType.bus,
              pattern: 0,
              trip: 0,
              departure: 100,
              arrival: 200,
            ),
        ],
      );
      expect(legLines(leg), ['33', '42', '68']);
    });

    test('the live vehicle sits at the last stop its delay has reached', () {
      // Board 10:00, two stops, alight 10:12, running 3 minutes late.
      final scheduled = [36000, 36300, 36600, 36720];
      // 3 min late: at 36400 only the board stop is behind it.
      expect(lastPassedIndex(scheduled, 180, 36400), 0);
      // 36600 + 180 is behind 36800, so it is at the second intermediate stop.
      expect(lastPassedIndex(scheduled, 180, 36800), 2);
      // Not started yet: nothing is highlighted.
      expect(lastPassedIndex(scheduled, 180, 35000), isNull);
      // On time it would already be one stop further at the same moment.
      expect(lastPassedIndex(scheduled, 0, 36400), 1);
    });

    test('transfers read in Italian', () {
      expect(transfersLabel(0), 'diretto');
      expect(transfersLabel(1), '1 cambio');
      expect(transfersLabel(3), '3 cambi');
    });
  });
}
