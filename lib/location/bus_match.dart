/// "Where is my bus": GTT's vehicle feed names the line only (no run, no
/// direction), so a vehicle is matched to a ride by line, heading along the
/// ride's pattern, and position on it.
library;

import 'dart:math' as math;

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/distance.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/link.dart';
import 'package:piedemove/routing/journey.dart';

/// A vehicle this far from the pattern is not on it.
const busMatchMaxOffMetres = 150.0;

/// On board: the rider's own vehicle is within this of the rider.
const busRiderMaxMetres = 120.0;

class ApproachingBus {
  const ApproachingBus({
    required this.vehicle,
    required this.routeShortName,
    required this.stopsAway,
    required this.metresAway,
  });

  final RtVehicle vehicle;
  final String routeShortName;

  /// Stops it still serves before the rider's: 0 = yours is its next stop.
  final int stopsAway;

  /// Along the route to the boarding stop.
  final double metresAway;
}

/// Where a point sits on [pattern] (stop to stop): the segment `from` stop
/// position, metres along the pattern, metres off it, and the segment's
/// heading. Null when the pattern has under two stops.
({int segment, double along, double off, double heading})? _onPattern(
    TransitIndex ix, int pattern, double lat, double lon) {
  final n = ix.patternLength(pattern);
  if (n < 2) return null;
  final kx = math.cos(lat * math.pi / 180) * 111320.0, ky = 110540.0;
  var cum = 0.0;
  ({int segment, double along, double off, double heading})? best;
  for (var i = 0; i + 1 < n; i++) {
    final a = ix.patternStopAt(pattern, i), b = ix.patternStopAt(pattern, i + 1);
    final ax = (ix.stopLon[a] - lon) * kx, ay = (ix.stopLat[a] - lat) * ky;
    final bx = (ix.stopLon[b] - lon) * kx, by = (ix.stopLat[b] - lat) * ky;
    final dx = bx - ax, dy = by - ay;
    final len = math.sqrt(dx * dx + dy * dy);
    final t = len == 0 ? 0.0 : (-(ax * dx + ay * dy) / (len * len)).clamp(0.0, 1.0);
    final px = ax + t * dx, py = ay + t * dy;
    final off = math.sqrt(px * px + py * py);
    if (best == null || off < best.off) {
      final heading = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
      best = (segment: i, along: cum + t * len, off: off, heading: heading);
    }
    cum += len;
  }
  return best;
}

double _alongAtStop(TransitIndex ix, int pattern, int pos) {
  var cum = 0.0;
  for (var i = 0; i < pos; i++) {
    final a = ix.patternStopAt(pattern, i), b = ix.patternStopAt(pattern, i + 1);
    cum += haversineMetres(
        ix.stopLat[a], ix.stopLon[a], ix.stopLat[b], ix.stopLon[b]);
  }
  return cum;
}

bool _sameWay(double? bearing, double heading) {
  if (bearing == null) return true; // unknown is not evidence against
  final d = ((bearing - heading) % 360 + 360) % 360;
  return math.min(d, 360 - d) < 90;
}

/// The nearest vehicle of [ride]'s lines still coming to its boarding stop,
/// heading the ride's way; null when none is known.
ApproachingBus? approachingBus(
    TransitIndex ix, Iterable<RtVehicle> vehicles, Leg ride) {
  ApproachingBus? best;
  for (final o in ride.options) {
    final p = o.pattern;
    var board = -1;
    for (var i = 0; i < ix.patternLength(p); i++) {
      if (ix.patternStopAt(p, i) == ride.fromStop) {
        board = i;
        break;
      }
    }
    if (board <= 0) continue; // boarding at the first stop: nothing upstream
    final boardAlong = _alongAtStop(ix, p, board);
    for (final v in vehicles) {
      if (routeIndexOf(ix, v) != ix.patternRoute[p]) continue;
      final at = _onPattern(ix, p, v.lat, v.lon);
      if (at == null || at.off > busMatchMaxOffMetres) continue;
      if (!_sameWay(v.bearing, at.heading)) continue;
      final metres = boardAlong - at.along;
      if (metres < -20) continue; // already past the stop
      if (best == null || metres < best.metresAway) {
        best = ApproachingBus(
          vehicle: v,
          routeShortName: o.routeShortName,
          stopsAway: math.max(0, board - at.segment - 1),
          metresAway: math.max(0, metres),
        );
      }
    }
  }
  return best;
}

/// On board: the vehicle of [ride]'s lines nearest the rider at ([lat],
/// [lon]), heading the ride's way, within [busRiderMaxMetres].
RtVehicle? riderVehicle(TransitIndex ix, Iterable<RtVehicle> vehicles,
    Leg ride, double lat, double lon) {
  RtVehicle? best;
  var bestD = busRiderMaxMetres;
  for (final o in ride.options) {
    for (final v in vehicles) {
      if (routeIndexOf(ix, v) != ix.patternRoute[o.pattern]) continue;
      final d = haversineMetres(lat, lon, v.lat, v.lon);
      if (d > bestD) continue;
      final at = _onPattern(ix, o.pattern, v.lat, v.lon);
      if (at == null || !_sameWay(v.bearing, at.heading)) continue;
      best = v;
      bestD = d;
    }
  }
  return best;
}
