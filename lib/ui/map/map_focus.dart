/// What the map is focused on (§9.9).
///
/// Focus is owned by [FocusController] and survives every sheet gesture.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/trip/trip_plan.dart';

@immutable
sealed class MapFocus {
  const MapFocus();
}

class RouteFocus extends MapFocus {
  const RouteFocus(this.route);
  final int route;

  @override
  bool operator ==(Object other) => other is RouteFocus && other.route == route;
  @override
  int get hashCode => route.hashCode;
}

class JourneyFocus extends MapFocus {
  const JourneyFocus(this.journey);
  final Journey journey;

  @override
  bool operator ==(Object other) =>
      other is JourneyFocus && identical(other.journey, journey);
  @override
  int get hashCode => identityHashCode(journey);
}

/// The one owner of what the map is focused on (§9.9).
///
/// A line or vehicle sheet, or a selected trip, *sets* it; only [close] (the
/// sheet's X, which falls back to the running or opened trip) and [cancella]
/// (the top pill) clear it. Minimising a sheet,
/// zooming, panning, a realtime tick or a lifecycle change never touch it.
class FocusController extends StateNotifier<MapFocus?> {
  FocusController(this._ref) : super(null) {
    // Stepping to a line or vehicle entity focuses it; stop and alert sheets
    // leave the current focus alone.
    _ref.listen<List<EntityRef>>(entityNavProvider, (_, stack) {
      final top = stack.lastOrNull;
      if (top == null) {
        // The last sheet went: back to the trip it was opened over, if any.
        final trip = _tripFocus();
        if (trip != null) state = trip;
      } else if (top is LineRef) {
        state = RouteFocus(top.route);
      } else if (top is VehicleRef) {
        final ix = _ref.read(transitIndexProvider).valueOrNull;
        final vehicle = _ref.read(realtimeProvider).vehicles[top.vehicleId];
        final route = vehicle?.routeId == null
            ? null
            : ix?.routeIndexById[vehicle!.routeId];
        if (route != null) state = RouteFocus(route);
      }
    });
    // Opening a trip's detail focuses its journey; stepping back to the list
    // (or clearing the trip) releases only a journey focus.
    _ref.listen<Journey?>(
      tripPlanProvider.select((t) {
        final list = t.result?.forTab(t.tab);
        final i = t.selected;
        return list != null && i != null && i < list.length ? list[i] : null;
      }),
      (_, journey) {
        if (journey != null) {
          state = JourneyFocus(journey);
        } else if (state is JourneyFocus) {
          state = null;
        }
      },
    );
  }

  final Ref _ref;

  /// X (or back) on a sheet: closes the sheet stack and drops the focus -
  /// except that a running or opened trip comes back, so a stop or line
  /// looked at mid-trip never loses the trip (rider report, beta 5).
  void close() {
    _ref.read(entityNavProvider.notifier).clear();
    state = _tripFocus();
  }

  /// The live trip's journey, else the trip open in the planner's detail.
  MapFocus? _tripFocus() {
    final live = _ref.read(liveTripProvider);
    if (live != null) return JourneyFocus(live.journey);
    final t = _ref.read(tripPlanProvider);
    final list = t.result?.forTab(t.tab);
    final i = t.selected;
    return list != null && i != null && i < list.length
        ? JourneyFocus(list[i])
        : null;
  }

  /// A live trip is running: the pill must confirm before [cancella].
  bool get needsConfirm => _ref.read(liveTripProvider) != null;

  /// Cancella pill: drops the focus, its sheets, the planned trip and any live
  /// trip. Callers confirm first when [needsConfirm].
  void cancella() {
    if (needsConfirm) _ref.read(liveTripProvider.notifier).stop();
    _ref.read(entityNavProvider.notifier).clear();
    if (state is JourneyFocus) _ref.read(tripPlanProvider.notifier).clear();
    state = null;
  }
}

final focusProvider =
    StateNotifierProvider<FocusController, MapFocus?>(FocusController.new);
