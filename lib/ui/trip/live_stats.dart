/// The numbers on the live strip (§12): when the next vehicle comes, when the
/// ride reaches the alight stop, and the trip as a whole - arrival time, time
/// and distance left. Pure: index, delays and the clock are passed in.
///
/// The next vehicle is read from the **live departures** at the boarding stop
/// for the lines that make the ride, not from the one run the planner picked:
/// that run was often gone or outside GTT's ~7-stop update window, so the
/// time sat still on "programmato" (rider report, beta 6). On board, the run
/// is the one whose departure was nearest the moment the ride began.
library;

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/routing/journey.dart';

class LiveStats {
  const LiveStats({
    required this.arrival,
    required this.arrivalLive,
    required this.metresLeft,
    this.next,
    this.then,
    this.alightAt,
    this.alightDelay,
  });

  /// Expected arrival at the destination.
  final DateTime arrival;

  /// True when [arrival] follows a live run, false when it is timetable.
  final bool arrivalLive;

  /// Along the rest of the current leg plus every leg after it.
  final double metresLeft;

  /// Walking to (or waiting for) a ride: the next vehicle of its lines at
  /// the boarding stop, live when the feed has it, and the one after.
  final Departure? next;
  final Departure? then;

  /// Riding: when the vehicle is expected at the alight stop.
  final DateTime? alightAt;
  final int? alightDelay;
}

/// Pattern positions of a ride leg's board and alight stops, or null.
(int, int)? _positions(TransitIndex ix, int pattern, Leg leg) {
  var from = -1;
  for (var p = 0; p < ix.patternLength(pattern); p++) {
    final stop = ix.patternStopAt(pattern, p);
    if (from < 0 && stop == leg.fromStop) {
      from = p;
    } else if (from >= 0 && stop == leg.toStop) {
      return (from, p);
    }
  }
  return null;
}

/// The run of ride [leg] boarded around [boardedSecs] (seconds of the
/// journey's service day): among its lines' runs today, the one whose
/// expected departure at the board stop is nearest, within 15 min; else the
/// planned one. Returns (pattern, trip, alight position).
(int, int, int)? boardedRun(TransitIndex ix, DelayLookup? delays, Leg leg,
    DateTime date, int boardedSecs) {
  if (leg.options.isEmpty) return null;
  final day = ix.dayIndexOf(date);
  (int, int, int)? best;
  var bestGap = 15 * 60 + 1;
  for (final o in leg.options) {
    final pos = _positions(ix, o.pattern, leg);
    if (pos == null) continue;
    for (var t = 0; t < ix.patternTripCount(o.pattern); t++) {
      final trip = ix.patternTripAt(o.pattern, t);
      if (day >= 0 &&
          day < ix.serviceDayCount &&
          !ix.serviceRunsOn(ix.tripService[trip], day)) {
        continue;
      }
      final dep = ix.depOf(trip, pos.$1) + (delays?.call(trip, pos.$1) ?? 0);
      final gap = (dep - boardedSecs).abs();
      if (gap < bestGap) {
        bestGap = gap;
        best = (o.pattern, trip, pos.$2);
      }
    }
  }
  if (best != null) return best;
  final o = leg.options.first;
  final pos = _positions(ix, o.pattern, leg);
  return pos == null ? null : (o.pattern, o.trip, pos.$2);
}

LiveStats liveStats(
  LiveTripState s,
  TransitIndex ix, {
  required DateTime now,
  DelayLookup? delays,
  UnavailableLookup? unavailable,
}) {
  final journey = s.journey;
  final legs = s.route.legs;
  final i = s.legIndex.clamp(0, legs.length - 1);
  final midnight = DateTime(journey.date.year, journey.date.month, journey.date.day);
  int secsOf(DateTime t) => t.difference(midnight).inSeconds;

  var metres = (s.leg.cumulative.last - s.along).clamp(0.0, double.infinity);
  for (var k = i + 1; k < legs.length; k++) {
    metres += legs[k].cumulative.last;
  }

  // Walking time after leg [k] to the destination, from the plan.
  int walkAfter(int k) {
    var secs = 0;
    for (var j = k + 1; j < journey.legs.length; j++) {
      secs += journey.legs[j].arrival - journey.legs[j].departure;
    }
    return secs;
  }

  final lastRide = journey.legs.lastIndexWhere((l) => l.kind == LegKind.ride);
  Departure? next, then;
  DateTime? alightAt;
  int? alightDelay;
  int? liveArrival; // seconds, when the last ride's run is known

  if (s.riding && i < journey.legs.length) {
    final leg = journey.legs[i];
    final run = boardedRun(ix, delays, leg, journey.date,
        secsOf(s.legStartedAt ?? now));
    if (run != null) {
      final (_, trip, pos) = run;
      alightDelay = delays?.call(trip, pos);
      final secs = ix.arrOf(trip, pos) + (alightDelay ?? 0);
      alightAt = journey.timeOf(secs);
      if (i == lastRide) liveArrival = secs + walkAfter(i);
    }
  } else {
    final k = journey.legs.indexWhere((l) => l.kind == LegKind.ride, i + 1);
    if (k >= 0) {
      final ride = journey.legs[k];
      final patterns = {for (final o in ride.options) o.pattern};
      final deps = [
        for (final d in nextDepartures(ix, ride.fromStop, now, 40,
            delays: delays, unavailable: unavailable))
          if (patterns.contains(d.pattern)) d,
      ];
      next = deps.firstOrNull;
      then = deps.length > 1 ? deps[1] : null;
      if (next != null && k == lastRide) {
        final pos = _positions(ix, next.pattern, ride);
        if (pos != null) {
          final arr = ix.arrOf(next.trip, pos.$2) +
              (delays?.call(next.trip, pos.$2) ?? 0);
          // Departure seconds are on the departure's own day.
          final shift = next.date.difference(midnight).inSeconds;
          liveArrival = arr + shift + walkAfter(k);
        }
      }
    }
  }

  var arrivalSecs = journey.arrival;
  var live = false;
  if (liveArrival != null) {
    arrivalSecs = liveArrival;
    live = alightDelay != null || (next?.live ?? false);
  } else if (lastRide >= 0) {
    final run = journey.legs[lastRide];
    final o = run.options.firstOrNull;
    final pos = o == null ? null : _positions(ix, o.pattern, run);
    final d = pos == null ? null : delays?.call(o!.trip, pos.$2);
    if (d != null) {
      arrivalSecs += d;
      live = true;
    }
  }

  return LiveStats(
    arrival: journey.timeOf(arrivalSecs),
    arrivalLive: live,
    metresLeft: metres,
    next: next,
    then: then,
    alightAt: alightAt,
    alightDelay: alightDelay,
  );
}

/// Whole minutes until [at], rounded up; 0 when due or past.
int minutesUntil(DateTime at, DateTime now) {
  final secs = at.difference(now).inSeconds;
  return secs <= 30 ? 0 : (secs / 60).ceil();
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
