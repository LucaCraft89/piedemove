/// What a finished trip shows (§12): where, when, how long, how much walking
/// and which lines. Built once, when the live trip reaches its end; pure.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/routing/journey.dart';

class TripSummary {
  const TripSummary({
    required this.destination,
    required this.startedAt,
    required this.arrivedAt,
    required this.plannedArrival,
    required this.walkMetres,
    required this.rides,
  });

  /// The planner's destination name, or null when it had none.
  final String? destination;
  final DateTime startedAt;
  final DateTime arrivedAt;
  final DateTime plannedArrival;

  /// Along the walking legs as drawn: approximate, always shown with "≈".
  final double walkMetres;

  /// Per ride, every line that could make it: (short name, route type).
  final List<List<(String, int)>> rides;

  Duration get duration => arrivedAt.difference(startedAt);

  /// Arrival against the plan, in whole minutes (+ late, - early).
  int get minutesLate =>
      (arrivedAt.difference(plannedArrival).inSeconds / 60).round();

  int get transfers => rides.isEmpty ? 0 : rides.length - 1;
}

TripSummary tripSummary(
  LiveTripState s, {
  required DateTime startedAt,
  required DateTime arrivedAt,
  String? destination,
}) {
  var walk = 0.0;
  for (final l in s.route.legs) {
    if (l.kind == LegKind.walk) walk += l.metres;
  }
  return TripSummary(
    destination: destination == null || destination.isEmpty ? null : destination,
    startedAt: startedAt,
    arrivedAt: arrivedAt,
    plannedArrival: s.journey.timeOf(s.journey.arrival),
    walkMetres: walk,
    rides: [
      for (final l in s.journey.legs)
        if (l.kind == LegKind.ride)
          [for (final o in l.options) (o.routeShortName, o.routeType)],
    ],
  );
}

/// `in orario`, `2 min in anticipo`, `3 min di ritardo`.
String punctualityLabel(int minutesLate) => switch (minutesLate) {
      0 => 'in orario',
      < 0 => '${-minutesLate} min in anticipo',
      _ => '$minutesLate min di ritardo',
    };

/// The last finished trip, until the rider closes its summary.
final tripSummaryProvider = StateProvider<TripSummary?>((ref) => null);
