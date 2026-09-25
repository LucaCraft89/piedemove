/// On-device smoke tour, run by CI on an Android emulator (tool/ci/emulator_smoke.sh).
///
/// Boots the real app, waits for the timetable index, then walks the screens a
/// user touches first: home, Linee browser, a line on the map, search, the
/// golden trip (Politecnico -> Via Cristalliera) and its detail. Every step
/// prints `PM_STEP <name>` and holds still, so the script can `adb screencap`
/// the real screen (the map is a platform view Flutter screenshots miss).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:piedemove/data/providers.dart';
import 'package:piedemove/main.dart' as app;
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/ui/home/home_page.dart';
import 'package:piedemove/ui/map/map_focus.dart';
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

Future<void> step(WidgetTester t, String name) async {
  await hold(t, const Duration(seconds: 3)); // tiles and layers settle
  // ignore: avoid_print
  print('PM_STEP $name');
  await hold(t, const Duration(seconds: 4)); // the script captures now
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('smoke tour', (t) async {
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
    await step(t, '01-home');

    // The chip row scrolls sideways; on a phone "Linee" starts off screen.
    final linee = find.widgetWithText(ActionChip, 'Linee');
    await t.scrollUntilVisible(linee, 120,
        scrollable: find
            .ancestor(
                of: find.widgetWithText(ActionChip, 'Cerca'),
                matching: find.byType(Scrollable))
            .first);
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

    plan.select(0);
    await step(t, '06-trip-detail');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
