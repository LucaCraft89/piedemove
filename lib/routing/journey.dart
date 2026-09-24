/// Result model. A ride leg carries **every** line that can make the hop — the
/// whole point of the product — each with its own next departure.
library;

import 'package:piedemove/geo/walk_router.dart';

class RideOption {
  const RideOption({
    required this.routeShortName,
    required this.routeType,
    required this.pattern,
    required this.trip,
    required this.departure,
    required this.arrival,
    this.detoured = false,
    this.scheduledOnly = false,
  });

  final String routeShortName;
  final int routeType;
  final int pattern;
  final int trip;

  /// Seconds from midnight of the journey's service day; may exceed 86400.
  final int departure;
  final int arrival;
  final bool detoured;

  /// Regione Piemonte bus: timetable only, no live data (phase 9).
  final bool scheduledOnly;
}

enum LegKind { walk, ride }

class Leg {
  const Leg({
    required this.kind,
    required this.fromStop,
    required this.toStop,
    required this.departure,
    required this.arrival,
    this.walkMetres = 0,
    this.options = const [],
    this.readyTime = 0,
    this.route,
  });

  final LegKind kind;

  /// Stop index, or -1 for the origin (first walk leg) / destination (last).
  final int fromStop;
  final int toStop;
  final int departure;
  final int arrival;
  final double walkMetres;

  /// Ride legs only: every line serving this hop inside the window.
  final List<RideOption> options;

  /// Earliest second the traveller can be at [fromStop] — the window start the
  /// every-line post-pass searches from.
  final int readyTime;

  /// Walk legs: the path on real pedestrian edges, when the walking graph
  /// covered both ends. Null = [walkMetres] is an estimate, shown with "≈".
  final WalkRoute? route;

  Leg withWalk({
    required double walkMetres,
    required int arrival,
    int? departure,
    WalkRoute? route,
  }) =>
      Leg(
        kind: kind,
        fromStop: fromStop,
        toStop: toStop,
        departure: departure ?? this.departure,
        arrival: arrival,
        walkMetres: walkMetres,
        options: options,
        readyTime: readyTime,
        route: route,
      );

  bool get detoured => options.any((o) => o.detoured);

  /// True when every line that can make this hop is scheduled only.
  bool get scheduledOnly =>
      options.isNotEmpty && options.every((o) => o.scheduledOnly);
}

class Journey {
  Journey(this.legs, this.date);

  final List<Leg> legs;

  /// Service day the leg times are relative to.
  final DateTime date;

  int get departure => legs.first.departure;
  int get arrival => legs.last.arrival;
  int get durationSeconds => arrival - departure;
  double get walkMetres =>
      legs.fold(0.0, (sum, l) => sum + l.walkMetres);

  /// True when some walk leg's distance is an estimate, not a routed path.
  bool get walkApproximate => legs
      .any((l) => l.kind == LegKind.walk && l.walkMetres > 0 && l.route == null);
  int get rides => legs.where((l) => l.kind == LegKind.ride).length;
  int get transfers => (rides - 1).clamp(0, 99);
  bool get detoured => legs.any((l) => l.detoured);
  bool get scheduledOnly => legs.any((l) => l.scheduledOnly);

  DateTime timeOf(int secondsFromMidnight) =>
      DateTime(date.year, date.month, date.day)
          .add(Duration(seconds: secondsFromMidnight));
}
