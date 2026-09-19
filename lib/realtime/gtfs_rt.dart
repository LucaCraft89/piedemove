/// GTFS-realtime decoding: FeedMessage -> the handful of records the app uses.
///
/// Field numbers come from `gtfs-realtime.proto`; anything not listed here is
/// skipped by [Pb]. Nothing throws: a malformed entity is dropped, never
/// patched, and a feed that fails to parse leaves the previous state in place.
library;

import 'dart:typed_data';

import 'pb.dart';

/// `VehiclePosition.VehicleStopStatus`.
enum VehicleStatus { incomingAt, stoppedAt, inTransitTo }

class RtVehicle {
  const RtVehicle({
    required this.id,
    required this.label,
    required this.tripId,
    required this.routeId,
    required this.lat,
    required this.lon,
    required this.bearing,
    required this.stopSequence,
    required this.stopId,
    required this.status,
    required this.timestamp,
  });

  final String id;
  final String? label;
  final String? tripId;
  final String? routeId;
  final double lat;
  final double lon;
  final double? bearing;
  final int? stopSequence;
  final String? stopId;
  final VehicleStatus status;
  final DateTime? timestamp;
}

/// GTT sends a rolling window of about seven stops ahead, keyed by
/// `stop_sequence` and with no `stop_id`; about half of the entries give an
/// absolute `time` instead of a `delay`, so both are kept.
class RtTripUpdate {
  const RtTripUpdate({
    required this.tripId,
    required this.routeId,
    required this.startDate,
    required this.tripDelay,
    required this.byStopId,
    required this.delayBySequence,
    required this.timeBySequence,
    required this.timestamp,
  });

  final String tripId;
  final String? routeId;

  /// `YYYYMMDD` of the service day the run belongs to.
  final String? startDate;

  /// `TripUpdate.delay` — the fallback when no stop matches.
  final int? tripDelay;

  /// Feeds that name stops rather than sequence numbers (not GTT today).
  final Map<String, int> byStopId;

  /// `stop_sequence` (1-based) -> delay in seconds.
  final Map<int, int> delayBySequence;

  /// `stop_sequence` -> absolute epoch seconds.
  final Map<int, int> timeBySequence;

  final DateTime? timestamp;
}

class RtAlert {
  const RtAlert({
    required this.id,
    required this.header,
    required this.description,
    required this.cause,
    required this.effect,
    required this.routeIds,
    required this.stopIds,
    required this.tripIds,
    required this.from,
    required this.to,
  });

  final String id;
  final String header;
  final String description;
  final int? cause;
  final int? effect;
  final Set<String> routeIds;
  final Set<String> stopIds;
  final Set<String> tripIds;
  final DateTime? from;
  final DateTime? to;

  bool activeAt(DateTime when) =>
      (from == null || !when.isBefore(from!)) &&
      (to == null || when.isBefore(to!));
}

class RtFeed {
  const RtFeed({
    this.vehicles = const [],
    this.tripUpdates = const [],
    this.alerts = const [],
    this.timestamp,
  });

  final List<RtVehicle> vehicles;
  final List<RtTripUpdate> tripUpdates;
  final List<RtAlert> alerts;
  final DateTime? timestamp;
}

RtFeed decodeFeed(Uint8List bytes) {
  final message = Pb.decode(bytes);
  final vehicles = <RtVehicle>[];
  final updates = <RtTripUpdate>[];
  final alerts = <RtAlert>[];

  for (final entity in message.all(2)) {
    try {
      _entity(entity, vehicles, updates, alerts);
    } catch (_) {
      // A malformed entity is dropped, never patched.
    }
  }

  return RtFeed(
    vehicles: vehicles,
    tripUpdates: updates,
    alerts: alerts,
    timestamp: _epoch(message.msg(1)?.int_(3)),
  );
}

void _entity(
  Pb entity,
  List<RtVehicle> vehicles,
  List<RtTripUpdate> updates,
  List<RtAlert> alerts,
) {
  final id = entity.str(1) ?? '';
  if (entity.int_(2) == 1) return; // is_deleted
  final vehicle = entity.msg(4);
  if (vehicle != null) {
    final v = _vehicle(id, vehicle);
    if (v != null) vehicles.add(v);
  }
  final update = entity.msg(3);
  if (update != null) {
    final u = _tripUpdate(update);
    if (u != null) updates.add(u);
  }
  final alert = entity.msg(5);
  if (alert != null) alerts.add(_alert(id, alert));
}

RtVehicle? _vehicle(String entityId, Pb v) {
  final position = v.msg(2);
  final lat = position?.float(1);
  final lon = position?.float(2);
  if (lat == null || lon == null) return null;
  final descriptor = v.msg(8);
  final trip = v.msg(1);
  return RtVehicle(
    id: descriptor?.str(1) ?? entityId,
    label: descriptor?.str(2),
    tripId: trip?.str(1),
    routeId: trip?.str(5),
    lat: lat,
    lon: lon,
    bearing: position?.float(3),
    stopSequence: v.int_(3),
    stopId: v.str(7),
    status: switch (v.int_(4)) {
      0 => VehicleStatus.incomingAt,
      1 => VehicleStatus.stoppedAt,
      _ => VehicleStatus.inTransitTo,
    },
    timestamp: _epoch(v.int_(5)),
  );
}

RtTripUpdate? _tripUpdate(Pb u) {
  final trip = u.msg(1);
  final tripId = trip?.str(1);
  if (tripId == null) return null;
  final byStopId = <String, int>{};
  final delayBySequence = <int, int>{};
  final timeBySequence = <int, int>{};
  for (final stu in u.all(2)) {
    // Departure first: it is what a waiting rider sees.
    final event = stu.msg(3) ?? stu.msg(2);
    if (event == null) continue;
    final delay = event.int_(1);
    final time = event.int_(2);
    final sequence = stu.int_(1);
    final stopId = stu.str(4);
    if (delay != null) {
      if (stopId != null) byStopId[stopId] = delay;
      if (sequence != null) delayBySequence[sequence] = delay;
    } else if (time != null && sequence != null) {
      timeBySequence[sequence] = time;
    }
  }
  return RtTripUpdate(
    tripId: tripId,
    routeId: trip?.str(5),
    startDate: trip?.str(3),
    tripDelay: u.int_(5),
    byStopId: byStopId,
    delayBySequence: delayBySequence,
    timeBySequence: timeBySequence,
    timestamp: _epoch(u.int_(4)),
  );
}

RtAlert _alert(String id, Pb a) {
  final routes = <String>{}, stops = <String>{}, trips = <String>{};
  for (final selector in a.all(5)) {
    final route = selector.str(2);
    if (route != null) routes.add(route);
    final stop = selector.str(5);
    if (stop != null) stops.add(stop);
    final trip = selector.msg(4)?.str(1);
    if (trip != null) trips.add(trip);
  }
  final period = a.all(1).firstOrNull;
  return RtAlert(
    id: id,
    header: _text(a.msg(10)),
    description: _text(a.msg(11)),
    cause: a.int_(6),
    effect: a.int_(7),
    routeIds: routes,
    stopIds: stops,
    tripIds: trips,
    from: _epoch(period?.int_(1)),
    to: _epoch(period?.int_(2)),
  );
}

/// Italian when the feed has it, otherwise the first translation.
String _text(Pb? translated) {
  if (translated == null) return '';
  String? fallback;
  for (final t in translated.all(1)) {
    final text = t.str(1);
    if (text == null) continue;
    final language = t.str(2)?.toLowerCase();
    if (language != null && language.startsWith('it')) return text;
    fallback ??= text;
  }
  return fallback ?? '';
}

DateTime? _epoch(int? seconds) => seconds == null || seconds <= 0
    ? null
    : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
