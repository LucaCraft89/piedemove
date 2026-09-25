import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/ui/map/map_focus.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/trip/trip_plan.dart';

/// A planner already showing [s] (a trip open in its detail).
class _Plan extends TripPlanController {
  _Plan(super.ref, TripState s) {
    state = s;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('focus survives sheet steps; only close and cancella clear it', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(focusProvider); // alive, so it listens
    final nav = c.read(entityNavProvider.notifier);

    nav.push(const LineRef(7));
    expect(c.read(focusProvider), const RouteFocus(7));

    nav.push(const StopRef(1)); // a stop sheet keeps the line focused
    expect(c.read(focusProvider), const RouteFocus(7));
    nav.pop();
    expect(c.read(focusProvider), const RouteFocus(7));

    c.read(focusProvider.notifier).close();
    expect(c.read(focusProvider), isNull);
    expect(c.read(entityNavProvider), isEmpty);

    nav.push(const LineRef(3));
    expect(c.read(focusProvider.notifier).needsConfirm, isFalse);
    c.read(focusProvider.notifier).cancella();
    expect(c.read(focusProvider), isNull);
  });

  test('closing a sheet opened over a trip brings the trip back', () {
    final journey = Journey(const [
      Leg(kind: LegKind.walk, fromStop: -1, toStop: -1, departure: 0,
          arrival: 60, walkMetres: 50),
    ], DateTime(2026, 9, 19));
    final c = ProviderContainer(overrides: [
      tripPlanProvider.overrideWith((ref) => _Plan(
            ref,
            TripState(
              result: TripResult(
                fastest: [journey],
                balanced: [journey],
                computedAt: DateTime(2026, 9, 19),
                query: const TripQuery(),
              ),
              selected: 0,
            ),
          )),
    ]);
    addTearDown(c.dispose);
    c.read(focusProvider);
    final nav = c.read(entityNavProvider.notifier);

    // A stop tapped mid-trip, then back: the trip, not an empty map.
    nav.push(const StopRef(1));
    c.read(focusProvider.notifier).close();
    expect(c.read(focusProvider), JourneyFocus(journey));

    // A line looked at mid-trip replaces the focus while open...
    nav.push(const LineRef(4));
    expect(c.read(focusProvider), const RouteFocus(4));
    // ...and closing it returns to the trip.
    c.read(focusProvider.notifier).close();
    expect(c.read(focusProvider), JourneyFocus(journey));
  });
}
