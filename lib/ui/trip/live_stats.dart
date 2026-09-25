/// The numbers under the live strip (§12): when the next vehicle comes, when
/// the ride reaches the alight stop, and the trip as a whole - arrival time,
/// time and distance left. Pure: the delay lookup is passed in.
library;

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/routing/departures.dart' show DelayLookup;
import 'package:piedemove/routing/journey.dart';

class LiveStats {
  const LiveStats({
    required this.arrival,
    required this.arrivalDelayKnown,
    required this.metresLeft,
    this.nextLine,
    this.nextDeparture,
    this.nextDelay,
    this.alightAt,
    this.alightDelay,
  });

  /// Expected arrival at the destination.
  final DateTime arrival;

  /// True when [arrival] includes a live delay, false when it is timetable.
  final bool arrivalDelayKnown;

  /// Along the rest of the current leg plus every leg after it.
  final double metresLeft;

  /// Walking to a ride: its line, when it is expected at the stop, and the
  /// live delay behind that (null = timetable only).
  final String? nextLine;
  final DateTime? nextDeparture;
  final int? nextDelay;

  /// Riding: when the vehicle is expected at the alight stop.
  final DateTime? alightAt;
  final int? alightDelay;
}

/// Delay of journey leg [leg]'s first option at its board (or alight) stop.
int? legDelay(TransitIndex ix, DelayLookup? delays, Leg leg,
    {bool atAlight = false}) {
  if (delays == null || leg.kind != LegKind.ride || leg.options.isEmpty) {
    return null;
  }
  final o = leg.options.first;
  final target = atAlight ? leg.toStop : leg.fromStop;
  var from = -1;
  for (var pos = 0; pos < ix.patternLength(o.pattern); pos++) {
    final stop = ix.patternStopAt(o.pattern, pos);
    if (from < 0 && stop == leg.fromStop) {
      from = pos;
      if (!atAlight) return delays(o.trip, pos);
    } else if (from >= 0 && stop == target) {
      return delays(o.trip, pos);
    }
  }
  return null;
}

LiveStats liveStats(
  LiveTripState s, {
  required int? Function(int legIndex, {bool atAlight}) delayOf,
}) {
  final journey = s.journey;
  final legs = s.route.legs;
  final i = s.legIndex.clamp(0, legs.length - 1);

  var metres = (s.leg.cumulative.last - s.along).clamp(0.0, double.infinity);
  for (var k = i + 1; k < legs.length; k++) {
    metres += legs[k].cumulative.last;
  }

  // Arrival: the timetable end, moved by the last ride's delay at its alight
  // stop (walking after it is not delayed by the vehicle).
  var arrivalSecs = journey.arrival;
  var delayKnown = false;
  final lastRide = journey.legs.lastIndexWhere((l) => l.kind == LegKind.ride);
  if (lastRide >= 0) {
    final d = delayOf(lastRide, atAlight: true);
    if (d != null) {
      arrivalSecs += d;
      delayKnown = true;
    }
  }

  String? nextLine;
  DateTime? nextDeparture, alightAt;
  int? nextDelay, alightDelay;
  if (s.riding && i < journey.legs.length) {
    alightDelay = delayOf(i, atAlight: true);
    alightAt = journey.timeOf(journey.legs[i].arrival + (alightDelay ?? 0));
  } else {
    final next = journey.legs.indexWhere((l) => l.kind == LegKind.ride, i + 1);
    if (next >= 0) {
      final ride = journey.legs[next];
      nextLine = ride.options.isEmpty ? null : ride.options.first.routeShortName;
      nextDelay = delayOf(next);
      nextDeparture = journey.timeOf(ride.departure + (nextDelay ?? 0));
    }
  }

  return LiveStats(
    arrival: journey.timeOf(arrivalSecs),
    arrivalDelayKnown: delayKnown,
    metresLeft: metres,
    nextLine: nextLine,
    nextDeparture: nextDeparture,
    nextDelay: nextDelay,
    alightAt: alightAt,
    alightDelay: alightDelay,
  );
}

/// `tra 4 min`, `ora`, `passato`, `tra 1 h 05`.
String untilLabel(DateTime at, DateTime now) {
  final secs = at.difference(now).inSeconds;
  if (secs < -30) return 'passato';
  if (secs < 60) return 'ora';
  final minutes = (secs / 60).ceil();
  if (minutes < 60) return 'tra $minutes min';
  return 'tra ${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';
}

/// `in orario`, `+3 min`, `-1 min`; null without live data.
String? delayLabel(int? delay) {
  if (delay == null) return null;
  if (delay.abs() < 60) return 'in orario';
  final m = (delay / 60).round();
  return m > 0 ? '+$m min' : '$m min';
}
