/// Joining live vehicles to the static index: trip id -> trip -> pattern.
library;

import 'package:piedemove/data/transit_index.dart';

import 'gtfs_rt.dart';
import 'store.dart';

/// The index trip a vehicle is running, or null when the feed names a trip the
/// cached index does not know (a fresher feed than the index).
int? tripIndexOf(TransitIndex ix, RtVehicle v) {
  final id = v.tripId;
  return id == null ? null : ix.tripIndexById[id];
}

int? routeIndexOf(TransitIndex ix, RtVehicle v) {
  final trip = tripIndexOf(ix, v);
  if (trip != null) return ix.patternRoute[ix.tripPattern[trip]];
  final id = v.routeId;
  return id == null ? null : ix.routeIndexById[id];
}

/// Position of the vehicle inside its pattern. `stop_sequence` is a feed value,
/// not an index position, so the stop id decides when there is one.
int? vehiclePosition(TransitIndex ix, int pattern, RtVehicle v) {
  final stopId = v.stopId;
  if (stopId != null) {
    final stop = ix.stopIndexById[stopId];
    if (stop != null) {
      for (var p = 0; p < ix.patternLength(pattern); p++) {
        if (ix.patternStopAt(pattern, p) == stop) return p;
      }
    }
  }
  final sequence = v.stopSequence;
  if (sequence == null) return null;
  // Feeds that number from 1 and never skip: the position is the offset.
  final guess = sequence - 1;
  return guess >= 0 && guess < ix.patternLength(pattern) ? guess : null;
}

List<RtVehicle> vehiclesOnRoute(TransitIndex ix, RealtimeState rt, int route) =>
    [
      for (final v in rt.vehicles.values)
        if (routeIndexOf(ix, v) == route) v,
    ];
