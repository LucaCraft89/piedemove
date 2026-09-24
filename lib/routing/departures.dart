/// Next departures at a stop, merged across every pattern serving it.
///
/// Powers home "nearby arrivals", the stop sheet, the line sheet and the result
/// cards. Handles today's trips and trips that started the previous service day
/// (GTFS times past 24:00).
library;

import 'package:piedemove/data/transit_index.dart';

import 'journey.dart' show serviceDayTime;
import 'raptor.dart' show secondsPerDay;

/// Realtime delay in seconds for a (trip, stop position), or null when the trip
/// has no live data. Wired to the trip-update store in phase 3.
typedef DelayLookup = int? Function(int trip, int stopPosition);

class Departure {
  const Departure({
    required this.stop,
    required this.pattern,
    required this.trip,
    required this.routeShortName,
    required this.routeType,
    required this.headsign,
    required this.scheduled,
    required this.delaySeconds,
    required this.date,
  });

  final int stop;
  final int pattern;
  final int trip;
  final String routeShortName;
  final int routeType;

  /// Last stop of the pattern — the destination shown on the vehicle.
  final String headsign;

  /// Seconds from midnight of [date]; may be negative for a trip that started
  /// the previous service day.
  final int scheduled;
  final int? delaySeconds;
  final DateTime date;

  bool get live => delaySeconds != null;
  int get expected => scheduled + (delaySeconds ?? 0);

  DateTime get time => serviceDayTime(date, expected);
}

/// How far back scheduled departures are checked for a delay that still puts
/// them ahead of now.
const lateLookbackSeconds = 30 * 60;

/// The next [n] departures at [stop] whose expected time is at or after [when].
List<Departure> nextDepartures(
  TransitIndex ix,
  int stop,
  DateTime when,
  int n, {
  DelayLookup? delays,
  int horizonSeconds = 3 * 3600,
}) {
  final date = DateTime(when.year, when.month, when.day);
  final todayIdx = ix.dayIndexOf(date);
  final from = when.hour * 3600 + when.minute * 60 + when.second;
  final out = <Departure>[];

  for (var i = ix.stopPatternOffset[stop];
      i < ix.stopPatternOffset[stop + 1];
      i++) {
    final pattern = ix.stopPattern[i];
    final pos = ix.stopPatternPos[i];
    if (pos == ix.patternLength(pattern) - 1) continue; // arrivals only
    final route = ix.patternRoute[pattern];
    final headsign = ix.stopNames[
        ix.patternStopAt(pattern, ix.patternLength(pattern) - 1)];

    for (final (dayIdx, offset) in [
      (todayIdx, 0),
      (todayIdx - 1, -secondsPerDay),
      // A horizon that crosses midnight reaches tomorrow's first runs.
      if (from + horizonSeconds >= secondsPerDay) (todayIdx + 1, secondsPerDay),
    ]) {
      if (dayIdx < 0 || dayIdx >= ix.serviceDayCount) continue;
      var added = 0;
      for (var t = 0; t < ix.patternTripCount(pattern); t++) {
        final trip = ix.patternTripAt(pattern, t);
        final scheduled = ix.depOf(trip, pos) + offset;
        // Scheduled time can be past while the bus is still coming: a late
        // run stays listed until its expected time, an early one leaves then.
        if (scheduled < from - lateLookbackSeconds) continue;
        if (scheduled > from + horizonSeconds) break;
        if (!ix.serviceRunsOn(ix.tripService[trip], dayIdx)) continue;
        final delay = delays?.call(trip, pos);
        if (scheduled + (delay ?? 0) < from) continue;
        out.add(Departure(
          stop: stop,
          pattern: pattern,
          trip: trip,
          routeShortName: ix.routeShortNames[route],
          routeType: ix.routeTypes[route],
          headsign: headsign,
          scheduled: scheduled,
          delaySeconds: delay,
          date: date,
        ));
        if (++added >= n) break;
      }
    }
  }

  out.sort((a, b) => a.expected.compareTo(b.expected));
  return out.length > n ? out.sublist(0, n) : out;
}
