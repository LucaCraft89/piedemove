/// What the map is focused on (§9.9).
///
/// Focus is derived, never set by hand: whatever is on top of the entity stack
/// or selected in the trip detail decides it, so closing a sheet restores the
/// ambient network with no extra bookkeeping.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/routing/journey.dart';
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

final mapFocusProvider = Provider<MapFocus?>((ref) {
  final entity = ref.watch(entityNavProvider).lastOrNull;
  if (entity is LineRef) return RouteFocus(entity.route);
  if (entity is VehicleRef) {
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    final vehicle =
        ref.watch(realtimeProvider.select((s) => s.vehicles))[entity.vehicleId];
    final route = vehicle?.routeId == null
        ? null
        : ix?.routeIndexById[vehicle!.routeId];
    if (route != null) return RouteFocus(route);
  }

  final trip = ref.watch(tripPlanProvider);
  final selected = trip.selected;
  final journeys = trip.result?.forTab(trip.tab);
  if (selected != null && journeys != null && selected < journeys.length) {
    return JourneyFocus(journeys[selected]);
  }
  return null;
});
