/// On-device smoke tour, run by CI on an Android emulator (tool/ci/emulator_smoke.sh).
///
/// Boots the real app, waits for the timetable index, then walks the screens a
/// user touches first: home, Linee browser, a line on the map, search, the
/// golden trip (Politecnico -> Via Cristalliera) and its detail. Every step
/// prints `PM_STEP <name>` and holds still, so the script can `adb screencap`
/// the real screen (the map is a platform view Flutter screenshots miss).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:piedemove/data/providers.dart';
import 'package:piedemove/main.dart' as app;
import 'package:piedemove/places/favourites.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/ui/home/home_page.dart';
import 'package:piedemove/ui/settings/settings_page.dart' show openSettings;
import 'package:piedemove/ui/sheets/nearby_sheet.dart' show stopsNear;
import 'package:piedemove/ui/map/map_focus.dart';
import 'package:piedemove/ui/map/map_view.dart' show mapControllerProvider;
import 'package:piedemove/ui/trip/trip_plan.dart';

/// Pumps frames for [d] of real time (the map and isolates keep running).
Future<void> hold(WidgetTester t, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps until [done] or [timeout]; false on timeout.
Future<bool> pumpUntil(WidgetTester t, bool Function() done,
    {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (done()) return true;
    await t.pump(const Duration(milliseconds: 250));
  }
  return done();
}

/// scrollUntilVisible stops once the chip is *built*, which can leave it
/// half past the edge of the row (a tap at x = -17 missed once): bring it
/// fully on screen before tapping.
Future<void> showChip(WidgetTester t, Finder chip) async {
  await t.ensureVisible(chip);
  await hold(t, const Duration(milliseconds: 500));
}

Future<void> step(WidgetTester t, String name) async {
  await hold(t, const Duration(seconds: 3)); // tiles and layers settle
  // ignore: avoid_print
  print('PM_STEP $name');
  await hold(t, const Duration(seconds: 4)); // the script captures now
}

/// How many features of [layer] are on screen: a layer added without error
/// can still draw nothing (sprite images dropped), which no screenshot of a
/// fallback underneath would tell.
Future<void> logRendered(ProviderContainer c, String layer) async {
  final map = c.read(mapControllerProvider);
  if (map == null) return;
  try {
    final hits = await map.queryRenderedFeaturesInRect(
        const Rect.fromLTWH(0, 0, 4000, 4000), [layer], null);
    // Which mode mixes the bubbles hold: a mixed one must draw as a pie.
    final mixes = <String, int>{};
    for (final h in hits) {
      final p = (h as Map)['properties'] as Map? ?? const {};
      final key = [for (final f in ['b', 't', 'm', 'f']) '$f${p[f]}'].join();
      mixes[key] = (mixes[key] ?? 0) + 1;
    }
    // ignore: avoid_print
    print('PM_RENDERED $layer ${hits.length} $mixes');
  } catch (e) {
    // ignore: avoid_print
    print('PM_RENDERED $layer failed: $e');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('smoke tour', (t) async {
    // A tap that would miss its widget fails right there, not 15 s later.
    WidgetController.hitTestWarningShouldBeFatal = true;
    app.main();
    await t.pump();
    final container =
        ProviderScope.containerOf(t.element(find.byType(HomePage)));

    // CI pushes a prebuilt index; without one the app downloads and builds
    // it on the emulator, which takes minutes.
    final ready = await pumpUntil(
        t, () => container.read(transitIndexProvider).hasValue,
        timeout: const Duration(minutes: 12));
    expect(ready, isTrue, reason: 'timetable index never loaded');
    // A favourite, so the home sheet shows its live board: the stop nearest
    // Politecnico, found in the data (no hard-coded id).
    final ix = container.read(transitIndexProvider).value!;
    final near = stopsNear(ix, 45.0626, 7.6624, radius: 600);
    if (near.isNotEmpty) {
      await container
          .read(favouritesProvider.notifier)
          .toggle(stopFavourite(ix.stopIds[near.first.$1]));
    }
    await step(t, '01-home');
    expect(find.text('Casa +'), findsOneWidget, reason: 'Casa chip');

    // The chip row scrolls sideways; on a phone "Linee" starts off screen.
    final linee = find.widgetWithText(ActionChip, 'Linee');
    await t.scrollUntilVisible(linee, 120,
        scrollable: find
            .ancestor(
                of: find.widgetWithText(ActionChip, 'Cerca'),
                matching: find.byType(Scrollable))
            .first);
    await showChip(t, linee);
    await t.tap(linee);
    expect(await pumpUntil(t, () => find.text('Metro').evaluate().isNotEmpty,
            timeout: const Duration(seconds: 15)),
        isTrue, reason: 'Linee page did not open');
    await step(t, '02-lines');

    await t.enterText(find.byType(TextField), '4');
    await hold(t, const Duration(seconds: 1));
    await t.tap(find.byType(ListTile).first);
    await step(t, '03-line-on-map');
    container.read(focusProvider.notifier).close();
    await hold(t, const Duration(seconds: 1));

    await t.scrollUntilVisible(find.widgetWithText(ActionChip, 'Cerca'), -120,
        scrollable: find
            .ancestor(
                of: find.widgetWithText(ActionChip, 'Filtri'),
                matching: find.byType(Scrollable))
            .first);
    await showChip(t, find.widgetWithText(ActionChip, 'Cerca'));
    await t.tap(find.widgetWithText(ActionChip, 'Cerca'));
    // The search route animates in; on a busy emulator 1 s was not always it.
    expect(await pumpUntil(t, () => find.byType(TextField).evaluate().isNotEmpty,
            timeout: const Duration(seconds: 15)),
        isTrue, reason: 'search page did not open');
    await t.enterText(find.byType(TextField), '68');
    await step(t, '04-search');
    // The Android system back, as a user leaves search.
    await t.binding.handlePopRoute();
    await hold(t, const Duration(seconds: 1));

    // The golden trip, on the next weekday at 18:00.
    var day = DateTime.now().add(const Duration(days: 1));
    while (day.weekday > DateTime.friday) {
      day = day.add(const Duration(days: 1));
    }
    final plan = container.read(tripPlanProvider.notifier)
      ..setFrom(const Place(
          name: 'Politecnico', address: '', lat: 45.0626, lon: 7.6624))
      ..setTo(const Place(
          name: 'Via Cristalliera', address: '', lat: 45.0738, lon: 7.6400))
      ..setWhen(WhenMode.departAt,
          DateTime(day.year, day.month, day.day, 18));
    await plan.plan();
    final planned = await pumpUntil(
        t, () => container.read(tripPlanProvider).result != null);
    expect(planned, isTrue, reason: 'planner never answered');
    final result = container.read(tripPlanProvider).result!;
    expect(result.failed, isFalse);
    expect(result.balanced, isNotEmpty, reason: 'no journey for the golden trip');
    await step(t, '05-trip-results');
    await logRendered(container, 'pm-stop-clusters');
    await logRendered(container, 'pm-stop-cluster-pies');
    await logRendered(container, 'pm-pins'); // start + destination

    plan.select(0);
    await step(t, '06-trip-detail');

    // Settings: the live-trip options and the offline map (beta 8).
    unawaited(openSettings(t.element(find.byType(HomePage))));
    // "Impostazioni" is also a home chip: wait for the page's own app bar.
    final bar = find.widgetWithText(AppBar, 'Impostazioni');
    expect(await pumpUntil(t, () => bar.evaluate().isNotEmpty,
            timeout: const Duration(seconds: 15)),
        isTrue, reason: 'settings did not open');
    final list = find
        .descendant(
            of: find.ancestor(of: bar, matching: find.byType(Scaffold)).first,
            matching: find.byType(Scrollable))
        .first;
    await t.scrollUntilVisible(find.text('2 fermate prima'), 200,
        scrollable: list);
    await step(t, '07-settings-live');
    await t.scrollUntilVisible(find.text('Scarica'), 200, scrollable: list);
    await step(t, '08-settings-offline');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
