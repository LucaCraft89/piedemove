/// Riverpod wiring for the planner: footpaths, the planner itself, and the
/// alert-driven filters (§8).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/store.dart';

import 'footpaths.dart';
import 'raptor.dart';

/// `Alert.Effect.NO_SERVICE` / `DETOUR`.
const effectNoService = 1;
const effectDetour = 4;

// ponytail: the footpath table is built on the UI isolate the first time
// something plans (~one pass over the stop grid). Move it to a compute() if a
// device ever shows a visible stall.
final footpathsProvider = Provider<Footpaths?>((ref) {
  final ix = ref.watch(transitIndexProvider).valueOrNull;
  if (ix == null) return null;
  return Footpaths.build(ix, clusters: ref.watch(stopClustersProvider));
});

final plannerProvider = Provider<Planner?>((ref) {
  final ix = ref.watch(transitIndexProvider).valueOrNull;
  final footpaths = ref.watch(footpathsProvider);
  if (ix == null || footpaths == null) return null;
  return Planner(ix, footpaths);
});

/// Stops a live alert suspends: excluded from planning entirely (§8).
final suspendedStopsProvider = Provider<Set<int>>((ref) {
  final ix = ref.watch(transitIndexProvider).valueOrNull;
  if (ix == null) return const {};
  final now = DateTime.now();
  final out = <int>{};
  for (final a in ref.watch(realtimeProvider).alerts) {
    if (a.effect != effectNoService || !a.activeAt(now)) continue;
    for (final id in a.stopIds) {
      final stop = ix.stopIndexById[id];
      if (stop != null) out.add(stop);
    }
  }
  return out;
});

/// Routes a live alert reroutes: kept, flagged, and penalised by the score.
final detouredRoutesProvider = Provider<Set<int>>((ref) {
  final ix = ref.watch(transitIndexProvider).valueOrNull;
  if (ix == null) return const {};
  final now = DateTime.now();
  final out = <int>{};
  for (final a in ref.watch(realtimeProvider).alerts) {
    if (a.effect != effectDetour || !a.activeAt(now)) continue;
    for (final id in a.routeIds) {
      final route = ix.routeIndexById[id];
      if (route != null) out.add(route);
    }
  }
  return out;
});

/// Alerts active right now, for the banner above the results list.
final activeAlertsProvider = Provider<List<RtAlert>>((ref) {
  final now = DateTime.now();
  return [
    for (final a in ref.watch(realtimeProvider).alerts)
      if (a.activeAt(now)) a,
  ];
});
