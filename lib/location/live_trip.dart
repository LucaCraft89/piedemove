/// Live trip (§12). The **rider's** position drives progress, never the
/// vehicle's: the vehicle's GTFS-RT position is only a fallback when the fix is
/// poor, and stays a separate concept everywhere else.
///
/// Foreground only: the position stream runs while the app is resumed and is
/// cancelled on pause, then re-synced on resume. No background service.
///
/// The geometry build and [advanceLive] are pure so the whole progress rule is
/// unit-testable without a phone: the controller below only wires sensors,
/// haptics and the wakelock to them.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/distance.dart';
import 'package:piedemove/geo/line_providers.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/walk_providers.dart';
import 'package:piedemove/geo/walk_router.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/settings/settings.dart';
import 'package:piedemove/location/bus_match.dart';
import 'package:piedemove/location/trip_history.dart';
import 'package:piedemove/location/trip_log.dart';
import 'package:piedemove/location/trip_summary.dart';
import 'package:piedemove/location/haptics.dart';
import 'package:piedemove/location/trip_notification.dart';
import 'package:piedemove/places/photon.dart' show Place;
import 'package:piedemove/ui/trip/live_stats.dart';
import 'package:piedemove/ui/trip/trip_format.dart' show hhmm, metresLabel;
import 'package:piedemove/ui/trip/trip_plan.dart';

/// Distances the rules turn on (§12), all metres.
/// Having been this close to the boarding stop arms the path rule below.
const liveBoardLatchRadius = 60.0;

/// Boarded by position: on the ride's own path, this far past the boarding
/// stop. A bus leaves the 40 m circle in ~5 s, often between two fixes and
/// before the phone reports a speed, so "at the stop and moving" alone almost
/// never fired on the road (rider report, beta 5).
const liveBoardedAlong = 60.0;

/// Aboard means moving along the ride's path faster than a person runs, over
/// at least [liveVehicleSpan]: sprinting after a bus at the stop, or along its
/// street, read as boarding it (rider report). m/s, ~27 km/h. A bus or tram
/// pulling out of a stop gets there within ~10-15 s; a rider chasing it does
/// not hold it for 6 s.
const liveVehicleSpeed = 7.5;
const liveVehicleSpan = Duration(seconds: 6);

/// And still advancing at this (m/s) since the previous fix: a GPS jump that
/// stays put afterwards is not a ride.
const liveBoardStepSpeed = 2.0;

/// Consecutive fixes that must agree before the walk becomes the ride.
const liveBoardVotes = 2;

/// How far back the boarding evidence reaches.
const liveBoardTrailFor = Duration(seconds: 30);
const liveAlightRadius = 60.0;
const liveWalkEndRadius = 25.0;
const liveOnRouteCutoff = 60.0;
const liveOffRouteMetres = 150.0;
const livePoorAccuracy = 50.0;

const liveOffRouteFor = Duration(seconds: 30);
const liveNoFixFor = Duration(seconds: 20);

/// A fix is only matched this far ahead of the current progress: on a loop or
/// a street run twice, a noisy fix must not jump to a later pass for good.
const liveProjectAheadMetres = 400.0;

/// A dead position stream is re-opened after this pause.
const liveStreamRetry = Duration(seconds: 5);

/// A cue the controller turns into a vibration exactly once.
enum LiveCue { oneStopLeft, alightNow }

/// One leg, flattened to a polyline plus the vertices its stops sit on.
@immutable
class LiveLeg {
  const LiveLeg({
    required this.kind,
    required this.lat,
    required this.lon,
    required this.cumulative,
    required this.stopVertex,
    required this.stopNames,
    required this.departure,
    required this.arrival,
    this.tripId,
    this.approximate = false,
    this.maneuvers = const [],
  });

  final LegKind kind;

  /// Routed walk legs: turns/crossings, `pointIndex` into this polyline.
  final List<Maneuver> maneuvers;

  /// Polyline in degrees; at least two points.
  final List<double> lat;
  final List<double> lon;

  /// Metres from the first vertex to each vertex.
  final List<double> cumulative;

  /// Ride legs: the vertex of every stop **after** boarding, alight last.
  final List<int> stopVertex;
  final List<String> stopNames;

  final int departure;
  final int arrival;

  /// The run the rider is on, when one was matched, for the live vehicle.
  final String? tripId;

  /// Straight-line geometry: no snapped path was available.
  final bool approximate;

  int get lastVertex => lat.length - 1;
  double get metres => cumulative.last;
  String get endName => stopNames.isEmpty ? '' : stopNames.last;
}

/// One good fix on the ride's path while walking to it.
typedef BoardSample = ({DateTime at, double along});

/// Pure: does [trail] (oldest first, newest = now) show vehicle motion - over
/// some span of at least [liveVehicleSpan] ending now, [liveVehicleSpeed] or
/// more along the path? Any span counts, so a bus that crept out of the stop
/// and then sped up qualifies as soon as it has sped up.
bool movingLikeAVehicleOn(List<BoardSample> trail) {
  if (trail.length < 2) return false;
  final now = trail.last;
  for (var k = trail.length - 2; k >= 0; k--) {
    final dt = now.at.difference(trail[k].at).inMilliseconds / 1000;
    if (dt < liveVehicleSpan.inMilliseconds / 1000) continue;
    if ((now.along - trail[k].along) / dt >= liveVehicleSpeed) return true;
  }
  return false;
}

/// The journey, flattened once when the trip starts.
@immutable
class LiveRoute {
  const LiveRoute(this.legs);
  final List<LiveLeg> legs;
}

/// One position report, from the device or from the fallback estimate.
@immutable
class LiveFix {
  const LiveFix({
    required this.lat,
    required this.lon,
    required this.accuracy,
    required this.speed,
    required this.at,
  });

  final double lat;
  final double lon;
  final double accuracy;

  /// Metres per second; negative when the platform does not know.
  final double speed;
  final DateTime at;
}

@immutable
class LiveTripState {
  const LiveTripState({
    required this.route,
    required this.journey,
    this.legIndex = 0,
    this.vertex = 0,
    this.along = 0,
    this.metresToEnd = 0,
    this.stopsRemaining = 0,
    this.estimated = false,
    this.offRoute = false,
    this.finished = false,
    this.offRouteSince,
    this.lastFix,
    this.cue,
    this.cueSeq = 0,
    this.reachedBoardStop = false,
    this.boardWaitAlong = -1,
    this.boardTrail = const [],
    this.boardVotes = 0,
    this.legStartedAt,
  });

  final LiveRoute route;
  final Journey journey;

  final int legIndex;

  /// Progress along the current leg's polyline. Monotone within a leg.
  final int vertex;

  /// Metres travelled along the current leg: the forward-only projection of
  /// the rider onto its polyline. The travelled/ahead boundary.
  final double along;

  final double metresToEnd;

  /// Ride legs: stops left before the alight stop, the alight stop included.
  final int stopsRemaining;

  /// The fix was poor or stale: the position shown is "posizione stimata".
  final bool estimated;

  /// More than 150 m off the leg for 30 s while riding, or the boarding
  /// vehicle left without the rider. Never recalculates by itself.
  final bool offRoute;

  final bool finished;
  final DateTime? offRouteSince;
  final DateTime? lastFix;

  /// Latest cue; [cueSeq] changes on every new one so a repeat still fires.
  final LiveCue? cue;
  final int cueSeq;

  /// Walking to a ride: the rider has been at the boarding stop
  /// ([liveBoardLatchRadius]). Reset on every leg change.
  final bool reachedBoardStop;

  /// Walking to a ride, once at the stop: the least metres along the ride's
  /// path the rider has been seen at (where they wait). Boarding is measured
  /// from here, not from the stop: a transfer pole a few metres behind the
  /// alight pole put the rider "60 m past it" on GPS noise alone. -1 = none.
  final double boardWaitAlong;

  /// Walking to a ride: recent good fixes on the ride's path, as metres
  /// along it, oldest first ([liveBoardTrailFor]). The boarding evidence.
  final List<BoardSample> boardTrail;

  /// Consecutive fixes that looked aboard ([liveBoardVotes] to board).
  final int boardVotes;

  /// When the current leg began (the fix that switched to it). On a ride it
  /// picks the run actually boarded, which may not be the planned one.
  final DateTime? legStartedAt;

  LiveLeg get leg => route.legs[legIndex.clamp(0, route.legs.length - 1)];
  bool get riding => leg.kind == LegKind.ride;
  bool get isLastLeg => legIndex >= route.legs.length - 1;

  LiveTripState copyWith({
    int? legIndex,
    int? vertex,
    double? along,
    double? metresToEnd,
    int? stopsRemaining,
    bool? estimated,
    bool? offRoute,
    bool? finished,
    DateTime? offRouteSince,
    DateTime? lastFix,
    LiveCue? cue,
    int? cueSeq,
    bool? reachedBoardStop,
    double? boardWaitAlong,
    List<BoardSample>? boardTrail,
    int? boardVotes,
    DateTime? legStartedAt,
    bool clearOffRouteSince = false,
    bool clearCue = false,
  }) => LiveTripState(
    route: route,
    journey: journey,
    legIndex: legIndex ?? this.legIndex,
    vertex: vertex ?? this.vertex,
    along: along ?? this.along,
    metresToEnd: metresToEnd ?? this.metresToEnd,
    stopsRemaining: stopsRemaining ?? this.stopsRemaining,
    estimated: estimated ?? this.estimated,
    offRoute: offRoute ?? this.offRoute,
    finished: finished ?? this.finished,
    offRouteSince: clearOffRouteSince
        ? null
        : (offRouteSince ?? this.offRouteSince),
    lastFix: lastFix ?? this.lastFix,
    cue: clearCue ? null : (cue ?? this.cue),
    cueSeq: cueSeq ?? this.cueSeq,
    reachedBoardStop: reachedBoardStop ?? this.reachedBoardStop,
    boardWaitAlong: boardWaitAlong ?? this.boardWaitAlong,
    boardTrail: boardTrail ?? this.boardTrail,
    boardVotes: boardVotes ?? this.boardVotes,
    legStartedAt: legStartedAt ?? this.legStartedAt,
  );
}

/// Flattens [journey] into polylines. [net] is optional: without snapped
/// geometry a leg falls back to its stop coordinates and is marked approximate.
LiveRoute buildLiveRoute(
  TransitIndex ix,
  LineNetwork? net,
  Journey journey, {
  double? originLat,
  double? originLon,
  double? destLat,
  double? destLon,
}) {
  final legs = <LiveLeg>[];
  for (final leg in journey.legs) {
    final lat = <double>[];
    final lon = <double>[];
    final stopVertex = <int>[];
    final stopNames = <String>[];
    var approximate = false;
    String? tripId;

    if (leg.kind == LegKind.ride && leg.options.isNotEmpty) {
      final option = leg.options.first;
      tripId = option.trip >= 0 && option.trip < ix.tripCount
          ? ix.tripIds[option.trip]
          : null;
      final from = _positionOf(ix, option.pattern, leg.fromStop);
      final to = from < 0
          ? -1
          : _positionOf(ix, option.pattern, leg.toStop, after: from + 1);
      final geom = net?[option.pattern];
      if (from >= 0 && to > from && geom != null && geom.vertexCount > 1) {
        final a = geom.stopVertex[from], b = geom.stopVertex[to];
        for (var v = a; v <= b; v++) {
          lat.add(geom.vertexLat[v] / 1e6);
          lon.add(geom.vertexLon[v] / 1e6);
        }
        for (var p = from + 1; p <= to; p++) {
          stopVertex.add((geom.stopVertex[p] - a).clamp(0, b - a));
          stopNames.add(
            cleanStopName(ix.stopNames[ix.patternStopAt(option.pattern, p)]),
          );
        }
      } else if (from >= 0 && to > from) {
        // No snapped path: the stops themselves are the polyline.
        approximate = true;
        for (var p = from; p <= to; p++) {
          final stop = ix.patternStopAt(option.pattern, p);
          lat.add(ix.stopLat[stop]);
          lon.add(ix.stopLon[stop]);
          if (p > from) {
            stopVertex.add(p - from);
            stopNames.add(cleanStopName(ix.stopNames[stop]));
          }
        }
      }
    }

    final walked = leg.kind == LegKind.walk ? leg.route : null;
    var maneuvers = const <Maneuver>[];
    if (walked != null && walked.polyline.length > 1) {
      // Routed walk: the real pedestrian path, not a chord.
      for (final p in walked.polyline) {
        lon.add(p[0]);
        lat.add(p[1]);
      }
      stopVertex.add(lat.length - 1);
      stopNames.add(
        leg.toStop >= 0 ? cleanStopName(ix.stopNames[leg.toStop]) : '',
      );
      maneuvers = walked.maneuvers;
    }

    if (lat.length < 2) {
      // Walk legs, and any ride leg whose geometry could not be resolved.
      approximate = true;
      // Same ends as walkLegEnds: a stop trip starts/ends at its pole.
      final a = leg.fromStop >= 0
          ? (ix.stopLat[leg.fromStop], ix.stopLon[leg.fromStop])
          : leg.placeStop >= 0
              ? (ix.stopLat[leg.placeStop], ix.stopLon[leg.placeStop])
              : (originLat == null || originLon == null
                  ? null
                  : (originLat, originLon));
      final b = leg.toStop >= 0
          ? (ix.stopLat[leg.toStop], ix.stopLon[leg.toStop])
          : leg.placeStop >= 0
              ? (ix.stopLat[leg.placeStop], ix.stopLon[leg.placeStop])
              : (destLat == null || destLon == null ? null : (destLat, destLon));
      lat
        ..clear()
        ..addAll([a?.$1 ?? b?.$1 ?? 0, b?.$1 ?? a?.$1 ?? 0]);
      lon
        ..clear()
        ..addAll([a?.$2 ?? b?.$2 ?? 0, b?.$2 ?? a?.$2 ?? 0]);
      stopVertex
        ..clear()
        ..add(1);
      stopNames
        ..clear()
        ..add(leg.toStop >= 0 ? cleanStopName(ix.stopNames[leg.toStop]) : '');
    }

    final cumulative = <double>[0];
    for (var i = 1; i < lat.length; i++) {
      cumulative.add(
        cumulative[i - 1] +
            haversineMetres(lat[i - 1], lon[i - 1], lat[i], lon[i]),
      );
    }

    legs.add(
      LiveLeg(
        kind: leg.kind,
        lat: lat,
        lon: lon,
        cumulative: cumulative,
        stopVertex: stopVertex,
        stopNames: stopNames,
        departure: leg.departure,
        arrival: leg.arrival,
        tripId: tripId,
        approximate: approximate,
        maneuvers: maneuvers,
      ),
    );
  }
  return LiveRoute(legs);
}

int _positionOf(TransitIndex ix, int pattern, int stop, {int after = 0}) {
  for (var i = after; i < ix.patternLength(pattern); i++) {
    if (ix.patternStopAt(pattern, i) == stop) return i;
  }
  return -1;
}

/// Advances [s] with one fix. Pure, monotone, and never recalculates the
/// journey: the worst it does is raise [LiveTripState.offRoute].
///
/// [vehicleLat]/[vehicleLon] is the matched vehicle when one is known — the
/// position of last resort when the fix is poor. It never boards the rider:
/// standing next to the bus is also what just missing it looks like. `walkSpeed` is the rider's own setting, in m/s.
LiveTripState advanceLive(
  LiveTripState s,
  LiveFix fix, {
  double? vehicleLat,
  double? vehicleLon,
  double walkSpeed = 1.2,
  int warnStops = 1,
}) {
  if (s.finished) return s;
  var state = s.copyWith(lastFix: fix.at, clearCue: true);
  final leg = state.leg;

  var lat = fix.lat, lon = fix.lon;
  var estimated = false;
  if (fix.accuracy > livePoorAccuracy) {
    // Metro, tunnels, urban canyons: the vehicle beats a 200 m fix.
    if (vehicleLat == null || vehicleLon == null) {
      // Nothing better to go on: a 120 m circle can sit on the alight stop
      // while the rider is a stop short. Hold progress, label it a guess.
      return state.copyWith(estimated: true);
    }
    lat = vehicleLat;
    lon = vehicleLon;
    estimated = true;
  }

  // Forward-only projection onto the segments from the last progress on.
  var proj = projectAhead(leg, lat, lon, state.along);
  if (s.estimated && !estimated && proj.distance > liveOnRouteCutoff) {
    // The last progress was a guess (no fix for a while, screen off): a good
    // fix now outranks it, even behind it. Without this, a guess that ran
    // ahead held the trip there for good (rider report, beta 11).
    final whole = projectAhead(leg, lat, lon, 0, maxAhead: leg.metres);
    if (whole.distance <= liveOnRouteCutoff) proj = whole;
  }
  var along = proj.along;
  var best = _vertexAt(leg, along);
  var bestMetres = proj.distance;

  if (bestMetres > liveOnRouteCutoff) {
    // Too far to trust: keep the last progress and say the position is a guess.
    along = state.along;
    best = state.vertex;
    estimated = true;
  }

  final endLat = leg.lat.last, endLon = leg.lon.last;
  final straightToEnd = haversineMetres(lat, lon, endLat, endLon);
  final alongToEnd = leg.metres - along;
  final metresToEnd = estimated
      ? math.min(alongToEnd, straightToEnd)
      : alongToEnd;

  var stopsRemaining = 0;
  for (final v in leg.stopVertex) {
    if (v > best) stopsRemaining++;
  }

  state = state.copyWith(
    vertex: best,
    along: along,
    estimated: estimated,
    metresToEnd: metresToEnd,
    stopsRemaining: stopsRemaining,
  );

  // Off route (riding only): 150 m away for 30 s, and only ever a banner.
  if (leg.kind == LegKind.ride && bestMetres > liveOffRouteMetres) {
    final since = state.offRouteSince ?? fix.at;
    state = state.copyWith(
      offRouteSince: since,
      offRoute: fix.at.difference(since) >= liveOffRouteFor,
    );
  } else {
    state = state.copyWith(offRoute: false, clearOffRouteSince: true);
  }

  // Alight cues: one stop out, then at the stop itself.
  if (leg.kind == LegKind.ride) {
    state = _alightCues(state, s.stopsRemaining, stopsRemaining, warnStops);
  }

  final boarding =
      leg.kind == LegKind.walk &&
      !state.isLastLeg &&
      state.route.legs[state.legIndex + 1].kind == LegKind.ride;
  final movingLikeAVehicle = fix.speed > walkSpeed * 1.6;

  if (boarding) {
    final ride = state.route.legs[state.legIndex + 1];
    final onRide = projectAhead(ride, lat, lon, 0, maxAhead: ride.metres);
    if (straightToEnd <= liveBoardLatchRadius && !state.reachedBoardStop) {
      state = state.copyWith(reachedBoardStop: true);
    }
    // Where the rider waits, on the ride's path (least seen while at stop).
    if (state.reachedBoardStop &&
        straightToEnd <= liveBoardLatchRadius &&
        onRide.distance <= liveOnRouteCutoff &&
        (state.boardWaitAlong < 0 || onRide.along < state.boardWaitAlong)) {
      state = state.copyWith(boardWaitAlong: onRide.along);
    }
    // Aboard: on the ride's path, 60 m past the stop *and* past where the
    // rider waited, moving faster than anyone runs for 6 s, still advancing,
    // on two fixes in a row. Speed is measured along the path from the fixes'
    // own times, not the phone's speed: a rider sprinting to the stop, or
    // after a bus that left, hit the old "1.6 x walking pace" at once.
    // A good fix (not the vehicle stand-in); "estimated" is no guard here:
    // past the stop the rider is off the walk leg, which is what sets it.
    if (fix.accuracy <= livePoorAccuracy &&
        onRide.distance <= liveOnRouteCutoff) {
      final sample = (at: fix.at, along: onRide.along);
      final prev = state.boardTrail.isEmpty ? null : state.boardTrail.last;
      final trail = [
        for (final t in state.boardTrail)
          if (fix.at.difference(t.at) <= liveBoardTrailFor) t,
        sample,
      ];
      final stepSeconds =
          prev == null ? 0 : fix.at.difference(prev.at).inMilliseconds / 1000;
      final advancing = prev != null &&
          stepSeconds > 0 &&
          (sample.along - prev.along) / stepSeconds >= liveBoardStepSpeed;
      final past = onRide.along >= liveBoardedAlong &&
          onRide.along >=
              math.max(0.0, state.boardWaitAlong) + liveBoardedAlong;
      final votes = past && advancing && movingLikeAVehicleOn(trail)
          ? state.boardVotes + 1
          : 0;
      state = state.copyWith(boardTrail: trail, boardVotes: votes);
      if (votes >= liveBoardVotes) {
        // Straight onto the ride, progress placed by this same fix.
        return advanceLive(nextLeg(state), fix,
            vehicleLat: vehicleLat,
            vehicleLon: vehicleLon,
            walkSpeed: walkSpeed,
            warnStops: warnStops);
      }
    }
  }

  // Near the alight stop but still moving like a vehicle: the rider is still
  // aboard. Say "get off" now, switch to the walk once they are off - an
  // early switch put the rider onto the next ride while still on this one.
  if (leg.kind == LegKind.ride &&
      straightToEnd <= liveAlightRadius &&
      movingLikeAVehicle) {
    return s.stopsRemaining > 0 && state.stopsRemaining > 0
        ? _cue(state.copyWith(stopsRemaining: 0), LiveCue.alightNow)
        : state.copyWith(stopsRemaining: 0);
  }

  final advance = switch (leg.kind) {
    LegKind.ride => straightToEnd <= liveAlightRadius,
    // To a ride, only the path rule above (or "Sono salito") boards: being
    // at the stop fast, or next to the bus, is also what chasing it looks
    // like.
    LegKind.walk => !boarding && straightToEnd <= liveWalkEndRadius,
  };
  if (advance) {
    final next = nextLeg(state);
    // Reaching the alight stop is the moment to get off: if the per-stop count
    // had not already said so (it usually still reads 1 here), say it now.
    return leg.kind == LegKind.ride && s.stopsRemaining > 0
        ? _cue(next, LiveCue.alightNow)
        : next;
  }
  return state;
}

/// Metres per second from [prev] to (lat, lon) at [at]; -1 when unknown
/// (no previous fix, too close in time, or too old to mean anything).
double derivedSpeed(LiveFix? prev, double lat, double lon, DateTime at) {
  if (prev == null) return -1;
  final dt = at.difference(prev.at).inMilliseconds / 1000;
  if (dt < 0.5 || dt > 30) return -1;
  return haversineMetres(prev.lat, prev.lon, lat, lon) / dt;
}

const liveNotificationTitle = 'PiedeMove · viaggio in corso';

/// One line for the trip notification, the strip's instruction in brief.
String liveNotificationText(LiveTripState s) {
  final leg = s.leg;
  final name = leg.endName;
  if (leg.kind == LegKind.ride) {
    final n = s.stopsRemaining;
    if (n <= 0) return 'Scendi ora${name.isEmpty ? '' : ' a $name'}';
    if (n == 1) return 'Scendi alla prossima: $name';
    return 'Scendi a $name tra $n fermate';
  }
  final i = s.legIndex + 1;
  if (i < s.journey.legs.length && s.journey.legs[i].kind == LegKind.ride) {
    final line = s.journey.legs[i].options.firstOrNull?.routeShortName ?? '';
    if (s.reachedBoardStop) return 'Aspetta il $line a $name';
    return 'A piedi verso $name (il $line): '
        '${((s.metresToEnd / 10).round() * 10).clamp(0, 1 << 30)} m';
  }
  return walkStripText(s);
}

/// The advance button's label, on the strip and in the notification.
String advanceLabel(LiveTripState s) {
  if (s.riding) return 'Sono sceso';
  final boarding = !s.isLastLeg && s.route.legs[s.legIndex + 1].kind == LegKind.ride;
  return boarding ? 'Sono salito' : 'Sono arrivato';
}

/// Share of the trip's length behind the rider, 0..100, for the
/// notification's progress bar.
int tripProgress(LiveTripState s) {
  var total = 0.0, done = 0.0;
  for (final (i, l) in s.route.legs.indexed) {
    total += l.metres;
    if (i < s.legIndex) done += l.metres;
  }
  if (s.finished) return 100;
  done += s.along.clamp(0.0, s.leg.metres);
  return total <= 0 ? 0 : (done * 100 / total).round().clamp(0, 100);
}

/// Result of [projectAhead].
typedef Projection = ({double along, double distance});

/// Projects (lat, lon) onto [leg]'s segments from [from] metres on (up to
/// [maxAhead] metres further), and
/// returns the nearest point's metres along the leg and its distance. Never
/// less than [from]: forward-only, so a fix behind the rider cannot rewind.
Projection projectAhead(LiveLeg leg, double lat, double lon, double from,
    {double maxAhead = liveProjectAheadMetres}) {
  var bestAlong = from;
  var bestDist = double.infinity;
  final kx = math.cos(lat * math.pi / 180) * 111320.0, ky = 110540.0;
  for (var i = 0; i + 1 < leg.lat.length; i++) {
    if (leg.cumulative[i + 1] < from) continue;
    if (leg.cumulative[i] > from + maxAhead) break;
    final ax = (leg.lon[i] - lon) * kx, ay = (leg.lat[i] - lat) * ky;
    final bx = (leg.lon[i + 1] - lon) * kx, by = (leg.lat[i + 1] - lat) * ky;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
    final px = ax + t * dx, py = ay + t * dy;
    final d = math.sqrt(px * px + py * py);
    if (d < bestDist) {
      bestDist = d;
      bestAlong =
          leg.cumulative[i] + t * (leg.cumulative[i + 1] - leg.cumulative[i]);
    }
  }
  return (along: math.max(bestAlong, from), distance: bestDist);
}

/// Last vertex at or before [along] metres (1 cm slack for float noise).
int _vertexAt(LiveLeg leg, double along) {
  var v = 0;
  while (v + 1 < leg.lat.length && leg.cumulative[v + 1] <= along + 0.01) {
    v++;
  }
  return v;
}

/// The active leg cut at the rider: `[lon, lat]` pairs, both including the
/// boundary point so the two lines join with no gap.
({List<List<double>> travelled, List<List<double>> ahead}) splitLeg(
  LiveLeg leg,
  double along,
) {
  final v = _vertexAt(leg, along);
  final travelled = <List<double>>[
    for (var i = 0; i <= v; i++) [leg.lon[i], leg.lat[i]],
  ];
  final ahead = <List<double>>[];
  var boundary = [leg.lon[v], leg.lat[v]];
  if (v + 1 < leg.lat.length) {
    final span = leg.cumulative[v + 1] - leg.cumulative[v];
    final t = span == 0
        ? 0.0
        : ((along - leg.cumulative[v]) / span).clamp(0.0, 1.0);
    boundary = [
      leg.lon[v] + t * (leg.lon[v + 1] - leg.lon[v]),
      leg.lat[v] + t * (leg.lat[v + 1] - leg.lat[v]),
    ];
    travelled.add(boundary);
    ahead.add(boundary);
    for (var i = v + 1; i < leg.lat.length; i++) {
      ahead.add([leg.lon[i], leg.lat[i]]);
    }
  } else {
    ahead.add(boundary);
  }
  return (travelled: travelled, ahead: ahead);
}

/// First maneuver of the leg still ahead of the rider, or null.
Maneuver? nextManeuver(LiveLeg leg, int vertex) {
  for (final m in leg.maneuvers) {
    if (m.pointIndex > vertex) return m;
  }
  return null;
}

/// Strip text for a walk leg: "Cammina ancora N m fino a STOP" (or "fino
/// alla destinazione" when the leg ends at a place, not a stop).
String walkStripText(LiveTripState s) {
  final n = ((s.metresToEnd / 10).round() * 10).clamp(0, 1 << 30);
  final name = s.leg.endName;
  return 'Cammina ancora $n m fino ${name.isEmpty ? 'alla destinazione' : 'a $name'}';
}

/// Off-route / "Ricalcola" for a walk leg: re-routes from the rider to where
/// the leg was heading and swaps it in with fresh progress. Null when the leg
/// is not a routed walk or the router finds nothing (the state is then kept).
LiveTripState? rerouteWalkLeg(
  LiveTripState s,
  double lat,
  double lon,
  WalkRouter router,
  WalkRoute current,
) {
  if (s.leg.kind != LegKind.walk || s.finished) return null;
  final r = router.reroute(lat, lon, current);
  if (r == null || r.polyline.length < 2) return null;
  final old = s.leg;
  final la = <double>[for (final p in r.polyline) p[1]];
  final lo = <double>[for (final p in r.polyline) p[0]];
  final cum = <double>[0];
  for (var i = 1; i < la.length; i++) {
    cum.add(cum[i - 1] + haversineMetres(la[i - 1], lo[i - 1], la[i], lo[i]));
  }
  final legs = [...s.route.legs];
  legs[s.legIndex] = LiveLeg(
    kind: LegKind.walk,
    lat: la,
    lon: lo,
    cumulative: cum,
    stopVertex: [la.length - 1],
    stopNames: old.stopNames,
    departure: old.departure,
    arrival: old.arrival,
    maneuvers: r.maneuvers,
  );
  return LiveTripState(
    route: LiveRoute(legs),
    journey: s.journey,
    legIndex: s.legIndex,
    metresToEnd: cum.last,
    stopsRemaining: 1,
    lastFix: s.lastFix,
    // Keep counting: a reset sequence would collide with the controller's
    // last vibrated cue and silence the next ride's first one.
    cueSeq: s.cueSeq,
  );
}

/// Marks the current leg done. Also the manual "Sono salito" / "Sono sceso".
LiveTripState nextLeg(LiveTripState s, {DateTime? at}) {
  if (s.isLastLeg) {
    return s.copyWith(finished: true, metresToEnd: 0, stopsRemaining: 0);
  }
  final index = s.legIndex + 1;
  final leg = s.route.legs[index];
  return s.copyWith(
    legIndex: index,
    vertex: 0,
    along: 0,
    metresToEnd: leg.metres,
    stopsRemaining: leg.stopVertex.length,
    offRoute: false,
    clearOffRouteSince: true,
    clearCue: true,
    reachedBoardStop: false,
    boardWaitAlong: -1,
    boardTrail: const [],
    boardVotes: 0,
    legStartedAt: at ?? s.lastFix,
  );
}

/// Alight cues for a ride whose count went from [before] to [now] stops:
/// the early warning when it first reaches [warnStops] (1 or 2, a setting),
/// then "get off" at the stop itself.
LiveTripState _alightCues(
    LiveTripState state, int before, int now, int warnStops) {
  if (now == 0 && before > 0) return _cue(state, LiveCue.alightNow);
  if (now >= 1 && now <= warnStops && before > warnStops) {
    return _cue(state, LiveCue.oneStopLeft);
  }
  return state;
}

LiveTripState _cue(LiveTripState s, LiveCue cue) =>
    s.copyWith(cue: cue, cueSeq: s.cueSeq + 1);

/// No fix for 20 s: hold the position, estimate from the schedule, and label
/// it. Called on a timer, so a stalled GPS still shows an honest strip.
LiveTripState staleLive(
  LiveTripState s,
  DateTime now, {
  DateTime? serviceStart,
  int delaySeconds = 0,
  int warnStops = 1,
}) {
  final last = s.lastFix;
  if (s.finished || last == null || now.difference(last) < liveNoFixFor) {
    return s;
  }
  return scheduleEstimate(s, now,
      serviceStart: serviceStart,
      delaySeconds: delaySeconds,
      warnStops: warnStops);
}

/// Progress from the timetable (moved by [delaySeconds]): linear along the
/// current leg between its two times, forward only, "posizione stimata".
LiveTripState scheduleEstimate(
  LiveTripState s,
  DateTime now, {
  DateTime? serviceStart,
  int delaySeconds = 0,
  int warnStops = 1,
}) {
  if (s.finished) return s;
  final leg = s.leg;
  var state = s.copyWith(estimated: true);
  if (serviceStart == null || leg.arrival <= leg.departure) return state;
  // A walk goes at the rider's pace, not the timetable's: they may not have
  // set off yet. Guessing moved the walk to its end with the screen off
  // (rider report, beta 11); hold it and say the position is a guess.
  if (leg.kind == LegKind.walk) return state;
  // Schedule-based estimate: linear along the leg between its two times.
  // A late run is behind its timetable: estimate from the expected times, or
  // "scendi ora" fires while the bus is still a stop or two away.
  final elapsed = now
      .difference(serviceDayTime(serviceStart, leg.departure + delaySeconds))
      .inSeconds;
  final fraction = (elapsed / (leg.arrival - leg.departure))
      .clamp(0.0, 1.0)
      .toDouble();
  final target = leg.metres * fraction;
  var v = state.vertex;
  while (v + 1 < leg.lat.length && leg.cumulative[v + 1] <= target) {
    v++;
  }
  if (v <= state.vertex || leg.cumulative[v] <= state.along) return state;
  var stopsRemaining = 0;
  for (final sv in leg.stopVertex) {
    if (sv > v) stopsRemaining++;
  }
  state = state.copyWith(
    vertex: v,
    along: leg.cumulative[v],
    metresToEnd: leg.metres - leg.cumulative[v],
    stopsRemaining: stopsRemaining,
  );
  if (leg.kind == LegKind.ride) {
    state = _alightCues(state, s.stopsRemaining, stopsRemaining, warnStops);
  }
  return state;
}

/// A metro ride: underground the phone's "position" is a Wi-Fi or cell guess
/// that can sit streets away while claiming good accuracy (rider report,
/// beta 10: off-route banner, progress frozen). So GPS is not used here:
/// the metro's own live position when the feed has it ([vehicleLat]),
/// else the timetable moved by the live delay. Never off route; never
/// leaves the ride by itself (surfacing near the exit, or "Sono sceso",
/// hands over to the walk).
LiveTripState undergroundLive(
  LiveTripState s,
  DateTime now, {
  DateTime? serviceStart,
  int delaySeconds = 0,
  double? vehicleLat,
  double? vehicleLon,
  int warnStops = 1,
}) {
  if (s.finished) return s;
  final calm = s.copyWith(offRoute: false, clearOffRouteSince: true);
  if (vehicleLat != null && vehicleLon != null) {
    final next = advanceLive(
        calm,
        LiveFix(
            lat: vehicleLat,
            lon: vehicleLon,
            accuracy: 10,
            speed: 10, // it is a train: do not read this as "got off"
            at: now),
        warnStops: warnStops);
    if (next.legIndex == s.legIndex) {
      return next.copyWith(
          estimated: true, offRoute: false, clearOffRouteSince: true);
    }
    // The train reached the stop: stay on the ride, "scendi ora" said.
    final end = s.leg.metres;
    return calm.copyWith(
      along: end,
      vertex: s.leg.lastVertex,
      metresToEnd: 0,
      stopsRemaining: 0,
      estimated: true,
      cue: next.cue,
      cueSeq: next.cueSeq,
    );
  }
  return scheduleEstimate(calm, now,
      serviceStart: serviceStart,
      delaySeconds: delaySeconds,
      warnStops: warnStops);
}

/// A bus that left this long ago without the rider is asked about.
const liveMissedAfter = Duration(seconds: 90);

/// Walking to (or waiting at) the stop of the next ride, and the run being
/// watched - the planned one, or the next after "Aspetto il prossimo" -
/// left its stop [liveMissedAfter] ago ([departure]: expected, with the
/// live delay). The rider is asked, never switched silently: they may be
/// aboard with the GPS not noticing yet.
bool missedRide(LiveTripState s, DateTime now, DateTime departure) {
  if (s.finished || s.riding || s.isLastLeg) return false;
  if (s.journey.legs[s.legIndex + 1].kind != LegKind.ride) return false;
  return now.difference(departure) > liveMissedAfter;
}

/// The ride the rider is heading for, while not on it yet.
Leg? nextRideLeg(LiveTripState s) {
  if (s.finished || s.riding || s.isLastLeg) return null;
  final l = s.journey.legs[s.legIndex + 1];
  return l.kind == LegKind.ride ? l : null;
}

/// True while the current leg is a metro ride.
bool isUnderground(LiveTripState s) {
  if (!s.riding || s.legIndex >= s.journey.legs.length) return false;
  final o = s.journey.legs[s.legIndex].options.firstOrNull;
  return o != null && o.routeType == RouteType.metro;
}

/// Surfaced at the exit: a good fix this close to the alight stop.
const liveSurfacedMetres = 150.0;

/// Sensors, haptics and the wakelock around the pure rules above.
///
/// ponytail: no sensor fusion is done — one fix in, one progress out. A Kalman
/// filter over accelerometer + GPS would go here if the raw fixes ever jitter
/// enough to move the strip about.
class LiveTripController extends StateNotifier<LiveTripState?>
    with WidgetsBindingObserver {
  LiveTripController(this._ref) : super(null);

  final Ref _ref;
  StreamSubscription<Position>? _sub;
  Timer? _stale;
  Timer? _retry;
  int _lastCueSeq = 0;
  LiveFix? _lastPos;
  LiveFix? _lastGood;

  /// What was last put in the trip notification (title, text, progress,
  /// button), so it is rewritten only when it changes.
  Object? _notified;

  /// The latest device fix, or null when none arrived yet.
  LiveFix? get lastFix => _lastPos;

  /// When [start] ran: the summary's trip time counts from here.
  DateTime? _startedAt;

  /// After "Aspetto il prossimo": the departure now watched instead of the
  /// planned one, for the leg it was given on.
  (int, DateTime)? _watchNext;

  void start(Journey journey) {
    final ix = _ref.read(transitIndexProvider).valueOrNull;
    if (ix == null) return;
    // A second start replaces the running trip; its timer and observer go.
    if (state != null) stop();
    final net = _ref.read(lineNetworkProvider).valueOrNull;
    // The first and last legs end at places, not stops: they need coordinates.
    final query = _ref.read(tripPlanProvider).query;
    final route = buildLiveRoute(
      ix,
      net,
      journey,
      originLat: query.from?.lat,
      originLon: query.from?.lon,
      destLat: query.to?.lat,
      destLon: query.to?.lon,
    );
    if (route.legs.isEmpty) return;
    final first = route.legs.first;
    state = LiveTripState(
      route: route,
      journey: journey,
      metresToEnd: first.metres,
      stopsRemaining: first.stopVertex.length,
    );
    _lastCueSeq = 0;
    _log.clear();
    _log.add('start: ${_legsSummary(ix, journey)}');
    _lastLogFix = null;
    _watchNext = null;
    _startedAt = DateTime.now();
    _ref.read(tripSummaryProvider.notifier).state = null;
    WidgetsBinding.instance.addObserver(this);
    _notified = null;
    // Android 13+: the trip notification needs the user's yes (asked once).
    unawaited(requestNotificationPermission());
    onTripNotificationAction(_onNotificationAction);
    _listen();
    _stale = Timer.periodic(const Duration(seconds: 5), (_) => _onStale());
    unawaited(_wake(true));
  }

  void stop() {
    if (state != null) {
      // Read only if running: the log must not start the feeds.
      final rt = _ref.exists(realtimeProvider)
          ? _ref.read(realtimeProvider)
          : const RealtimeState();
      final now = DateTime.now();
      _log.add('stop at leg ${state!.legIndex}${state!.finished ? ' (arrived)' : ''}; feeds: ${[
        for (final k in RtFeedKind.values)
          '${k.name} ${rt.health[k]?.lastSuccess == null ? 'never' : '${now.difference(rt.health[k]!.lastSuccess!).inSeconds}s'}${rt.health[k]?.lastError == null ? '' : ' (${rt.health[k]!.lastError})'}'
      ].join(', ')}');
      unawaited(_log.save());
    }
    _sub?.cancel();
    _sub = null;
    _stale?.cancel();
    _stale = null;
    _retry?.cancel();
    _retry = null;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_wake(false));
    unawaited(cancelTripNotification());
    _notified = null;
    _watchNext = null;
    _riskBuzzed = null;
    _ref.read(missedRideProvider.notifier).state = null;
    _ref.read(connectionRiskProvider.notifier).state = null;
    state = null;
  }

  /// "Sono salito" / "Sono sceso": always available, whatever the sensors say.
  void manualAdvance() {
    final s = state;
    if (s == null) return;
    final next = nextLeg(s, at: DateTime.now());
    _log.add('manual: ${advanceLabel(s)} (leg ${s.legIndex} -> ${next.legIndex})');
    _ref.read(missedRideProvider.notifier).state = null;
    state = next;
    if (next.finished) {
      _finish(next);
    } else {
      _notify(next);
    }
  }

  /// Arrived: the summary replaces the strip, then everything stops.
  void _finish(LiveTripState s) {
    final now = DateTime.now();
    final summary = tripSummary(s,
        startedAt: _startedAt ?? now,
        arrivedAt: now,
        destination: _ref.read(tripPlanProvider).query.to?.name);
    _ref.read(tripSummaryProvider.notifier).state = summary;
    unawaited(_ref.read(tripHistoryProvider.notifier).add(TripRecord.of(summary)));
    stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (this.state == null) return;
    if (state == AppLifecycleState.resumed) {
      _listen();
      unawaited(_wake(true));
    } else {
      // Screen off or another app: the position stream keeps running in the
      // foreground service (its notification says so), so progress and the
      // "scendi" vibrations go on in a pocket. Only the screen may sleep.
      unawaited(_wake(false));
    }
  }

  void _listen() {
    if (_sub != null) return;
    try {
      _sub =
          Geolocator.getPositionStream(
            // A fix a second: the plain settings gave Android's default of
            // one every ~5 s, 40+ m apart at bus speed.
            locationSettings: AndroidSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              intervalDuration: const Duration(seconds: 1),
              // A foreground service: fixes keep coming with the screen off
              // (rider request). Its notification is rewritten live below.
              foregroundNotificationConfig: const ForegroundNotificationConfig(
                notificationTitle: liveNotificationTitle,
                notificationText: 'Segue la tua posizione',
                notificationChannelName: 'Viaggio live',
                // The white footprint, not the colour launcher icon (a blob
                // in the status bar).
                notificationIcon: AndroidResource(
                    name: 'ic_stat_piedemove', defType: 'drawable'),
                enableWakeLock: true,
                setOngoing: true,
              ),
            ),
          ).listen(
            _onFix,
            onError: (Object e) {
              debugPrint('pm: live position stream failed: $e');
              _restartSoon();
            },
            onDone: _restartSoon,
          );
    } catch (e) {
      debugPrint('pm: live position stream unavailable: $e');
      _restartSoon();
    }
  }

  /// Location switched off or the stream died in the foreground: drop it and
  /// try again shortly, instead of waiting for a pause/resume.
  void _restartSoon() {
    _sub?.cancel();
    _sub = null;
    _retry?.cancel();
    if (state == null) return;
    // Background too: the trip is running in a pocket.
    _retry = Timer(liveStreamRetry, () {
      if (state != null) _listen();
    });
  }

  /// "Ricalcola" on a walk leg: re-route from the last fix. False when there
  /// is no fix, no graph or no route, so the caller can fall back to a replan.
  bool recalculateWalk() {
    final s = state, p = _lastPos;
    final source = _ref.read(walkRouterProvider).valueOrNull;
    if (s == null || p == null || source == null) return false;
    final leg = s.leg;
    final cur = WalkRoute(
      [
        for (var i = 0; i < leg.lat.length; i++) [leg.lon[i], leg.lat[i]],
      ],
      leg.metres,
      leg.maneuvers,
    );
    final next = rerouteWalkLeg(s, p.lat, p.lon, source.router, cur);
    if (next == null) return false;
    state = next;
    return true;
  }

  void _onFix(Position p) {
    final s = state;
    if (s == null) return;
    final now = DateTime.now();
    final prev = _lastPos;
    final fix = LiveFix(
      lat: p.latitude,
      lon: p.longitude,
      accuracy: p.accuracy,
      // Many phones report 0 or nothing: fall back to the move since the
      // previous fix.
      speed: p.speed > 0 ? p.speed : derivedSpeed(prev, p.latitude, p.longitude, now),
      at: now,
    );
    _lastPos = fix;
    if (_lastLogFix == null ||
        now.difference(_lastLogFix!) >= const Duration(seconds: 10)) {
      _lastLogFix = now;
      _log.add('fix ${logPos(fix.lat, fix.lon)} acc ${fix.accuracy.round()} m '
          'speed ${fix.speed.toStringAsFixed(1)} m/s; leg ${s.legIndex} '
          '${s.leg.kind.name} along ${s.along.round()}/${s.leg.metres.round()} m'
          '${s.estimated ? ' est' : ''}${isUnderground(s) ? ' underground' : ''}');
    }
    if (fix.accuracy <= livePoorAccuracy) _lastGood = fix;
    if (isUnderground(s)) {
      final est = _underground(s, now);
      // Out of the station: a real fix near the exit hands over to the walk.
      final surfaced = fix.accuracy <= 30 &&
          haversineMetres(fix.lat, fix.lon, s.leg.lat.last, s.leg.lon.last) <=
              liveSurfacedMetres &&
          est.stopsRemaining <= 1;
      _apply(surfaced
          ? advanceLive(nextLeg(est, at: now), fix,
              walkSpeed: _ref.read(settingsProvider).walkSpeed,
              warnStops: _ref.read(settingsProvider).alightWarnStops)
          : est.copyWith(lastFix: now));
      return;
    }
    final vehicle = _vehicleFor(s);
    final next = advanceLive(
      s,
      fix,
      vehicleLat: vehicle?.lat,
      vehicleLon: vehicle?.lon,
      walkSpeed: _ref.read(settingsProvider).walkSpeed,
      warnStops: _ref.read(settingsProvider).alightWarnStops,
    );
    _apply(next);
  }

  void _onStale() {
    final s = state;
    if (s == null) return;
    _checkMissed(s, DateTime.now());
    _checkConnection(s, DateTime.now());
    // Underground the timetable moves the trip on, fixes or not.
    if (isUnderground(s)) {
      _apply(_underground(s, DateTime.now()));
      return;
    }
    final date = s.journey.date;
    _apply(
      staleLive(
        s,
        DateTime.now(),
        serviceStart: DateTime(date.year, date.month, date.day),
        delaySeconds: _knownDelay(s) ?? 0,
        warnStops: _ref.read(settingsProvider).alightWarnStops,
      ),
    );
  }

  /// The run's latest reported delay, if the trip-update feed has one.
  /// Asks "Hai perso il …?" once the watched departure is well past.
  void _checkMissed(LiveTripState s, DateTime now) {
    final ride = nextRideLeg(s);
    final prompt = _ref.read(missedRideProvider.notifier);
    if (ride == null) {
      if (prompt.state != null) prompt.state = null;
      return;
    }
    final watched = _watchNext;
    final departure = watched != null && watched.$1 == s.legIndex
        ? watched.$2
        : s.journey.timeOf(ride.departure + (_boardDelay(ride) ?? 0));
    final missed = missedRide(s, now, departure);
    final names = {for (final o in ride.options) o.routeShortName}.join(', ');
    if (missed && prompt.state == null) {
      _log.add('asked: missed $names (left ${departure.toIso8601String().substring(11, 16)})');
      prompt.state = names;
      unawaited(vibrateCue(LiveCue.oneStopLeft,
          sound: _ref.read(settingsProvider).alightSound));
    } else if (!missed && prompt.state != null) {
      prompt.state = null;
    }
  }

  /// The change ahead at risk (late bus, tight walk): a banner and one buzz
  /// per planned run, seen from the bus instead of at the stop.
  void _checkConnection(LiveTripState s, DateTime now) {
    final ix = _ref.read(transitIndexProvider).valueOrNull;
    final risk = ix == null
        ? null
        : connectionRisk(s, ix,
            now: now,
            delays: _ref.read(delayLookupProvider),
            unavailable: _ref.read(unavailableLookupProvider));
    final holder = _ref.read(connectionRiskProvider.notifier);
    final before = holder.state;
    if (risk == null) {
      if (before != null) {
        holder.state = null;
        _notify(s);
      }
      return;
    }
    final key = (risk.lines, risk.planned);
    if (key != _riskBuzzed) {
      _riskBuzzed = key;
      _log.add('connection at risk: ${connectionRiskLabel(risk)}');
      unawaited(vibrateCue(LiveCue.oneStopLeft,
          sound: _ref.read(settingsProvider).alightSound));
    }
    holder.state = risk;
    if (before == null ||
        connectionRiskLabel(before) != connectionRiskLabel(risk)) {
      _notify(s); // the notification says it too
    }
  }

  /// The planned run last buzzed about.
  Object? _riskBuzzed;

  TripLog get _log => _ref.read(tripLogProvider);

  /// When a fix was last written to the log (one every 10 s).
  DateTime? _lastLogFix;

  /// `walk 80 m > 2 PORTA NUOVA 08:00 -> BARDONECCHIA 08:14 > walk 300 m`.
  static String _legsSummary(TransitIndex ix, Journey j) => [
        for (final l in j.legs)
          l.kind == LegKind.walk
              ? 'walk ${l.walkMetres.round()} m'
              : '${{for (final o in l.options) o.routeShortName}.join('/')} '
                  '${ix.stopNames[l.fromStop]} ${hhmm(j.timeOf(l.departure))} -> '
                  '${ix.stopNames[l.toStop]} ${hhmm(j.timeOf(l.arrival))}',
      ].join(' > ');

  /// The live delay of the planned run at the ride's board stop.
  int? _boardDelay(Leg ride) {
    final ix = _ref.read(transitIndexProvider).valueOrNull;
    final delays = _ref.read(delayLookupProvider);
    final o = ride.options.firstOrNull;
    if (ix == null || delays == null || o == null) return null;
    for (var p = 0; p < ix.patternLength(o.pattern); p++) {
      if (ix.patternStopAt(o.pattern, p) == ride.fromStop) {
        return delays(o.trip, p);
      }
    }
    return null;
  }

  /// The notification says what the strip says, when it changes: the
  /// instruction, arrival and distance left, a progress bar (2 % steps) and
  /// the advance button, usable with the phone locked.
  void _notify(LiveTripState s) {
    if (s.finished) return;
    final title = liveNotificationText(s);
    var text = liveNotificationTitle;
    final ix = _ref.read(transitIndexProvider).valueOrNull;
    if (ix != null) {
      final stats = liveStats(s, ix,
          now: DateTime.now(),
          delays: _ref.read(delayLookupProvider),
          unavailable: _ref.read(unavailableLookupProvider));
      text = 'Arrivo ${hhmm(stats.arrival)}'
          '${stats.arrivalLive ? '' : ' (orario)'}'
          ' · mancano ${metresLabel(stats.metresLeft)}';
    }
    final risk = _ref.read(connectionRiskProvider);
    if (risk != null && s.riding) text = connectionRiskLabel(risk);
    final progress = tripProgress(s) ~/ 2 * 2;
    final primary = advanceLabel(s);
    final key = (title, text, progress, primary);
    if (key == _notified) return;
    _notified = key;
    unawaited(showTripNotification(title, text,
        progress: progress, primary: primary));
  }

  /// A button in the notification: the same as on the strip.
  void _onNotificationAction(String action) {
    if (state == null) return;
    _log.add('notification button: $action');
    switch (action) {
      case 'advance':
        manualAdvance();
      case 'stop':
        stop();
    }
  }

  /// "Aspetto il prossimo": keep the trip, watch [next] (the next vehicle
  /// of the ride's lines, null when unknown: ten minutes from now).
  void waitForNext(DateTime? next) {
    final s = state;
    if (s == null) return;
    _log.add('answer: waiting for the next one');
    _watchNext = (
      s.legIndex,
      next ?? DateTime.now().add(const Duration(minutes: 10)),
    );
    _ref.read(missedRideProvider.notifier).state = null;
  }

  /// "Sì, ricalcola": plan again from here, now, and go on live with the
  /// best answer (the results stay on screen when there is none).
  Future<void> replanFromHere() async {
    _log.add('answer: missed it, replanning');
    final fix = _lastGood ?? _lastPos;
    stop();
    final plan = _ref.read(tripPlanProvider.notifier);
    if (fix != null) {
      plan.setFrom(Place(
          name: 'La mia posizione', address: '', lat: fix.lat, lon: fix.lon));
    }
    plan.setWhen(WhenMode.now);
    await plan.plan();
    final trip = _ref.read(tripPlanProvider);
    final best = trip.result?.forTab(trip.tab).firstOrNull;
    if (best == null || state != null) return;
    plan.select(0);
    start(best);
  }

  int? _knownDelay(LiveTripState s) {
    final tripId = s.leg.tripId;
    if (tripId == null) return null;
    final u = _ref.read(realtimeProvider).tripUpdates[tripId];
    if (u == null) return null;
    if (u.delayBySequence.isNotEmpty) {
      final last = u.delayBySequence.keys.reduce(math.max);
      return u.delayBySequence[last];
    }
    return u.tripDelay;
  }

  void _apply(LiveTripState next) {
    final before = state;
    if (before != null) {
      if (next.legIndex != before.legIndex) {
        _log.add('leg ${before.legIndex} -> ${next.legIndex} (auto)');
      }
      if (next.offRoute != before.offRoute) _log.add('off route: ${next.offRoute}');
      if (next.cue != null && next.cueSeq != before.cueSeq) {
        _log.add('cue ${next.cue!.name}');
      }
    }
    state = next;
    _notify(next);
    if (next.cue != null && next.cueSeq != _lastCueSeq) {
      _lastCueSeq = next.cueSeq;
      unawaited(vibrateCue(next.cue!,
          sound: _ref.read(settingsProvider).alightSound));
    }
    if (next.finished) _finish(next);
  }

  /// [undergroundLive] with the metro's live position when the feed has it:
  /// the train of the ride's line, heading its way, nearest where the
  /// timetable puts the rider's train.
  LiveTripState _underground(LiveTripState s, DateTime now) {
    final date = s.journey.date;
    final start = DateTime(date.year, date.month, date.day);
    final delay = _knownDelay(s) ?? 0;
    final ix = _ref.read(transitIndexProvider).valueOrNull;
    final leg = s.journey.legs[s.legIndex];
    final elapsed = now
        .difference(serviceDayTime(start, leg.departure + delay))
        .inSeconds;
    final fraction = leg.arrival <= leg.departure
        ? 0.0
        : (elapsed / (leg.arrival - leg.departure)).clamp(0.0, 1.0).toDouble();
    final train = ix == null
        ? null
        : trainNearSchedule(ix, _ref.read(realtimeProvider).vehicles.values,
            leg, fraction);
    return undergroundLive(s, now,
        serviceStart: start,
        delaySeconds: delay,
        vehicleLat: train?.lat,
        vehicleLon: train?.lon,
        warnStops: _ref.read(settingsProvider).alightWarnStops);
  }

  /// On board: the rider's vehicle - by run id when the feed has one (GTT's
  /// does not), else by line, heading and nearness to the rider
  /// ([riderVehicle]). It stands in for a poor fix (tunnels, the metro).
  /// Never while walking: a bus pulling in must not "board" anyone.
  RtVehicle? _vehicleFor(LiveTripState s) {
    if (!s.riding) return null;
    final vehicles = _ref.read(realtimeProvider).vehicles;
    final tripId = s.leg.tripId;
    if (tripId != null) {
      for (final v in vehicles.values) {
        if (v.tripId == tripId) return v;
      }
    }
    final ix = _ref.read(transitIndexProvider).valueOrNull;
    // Matched near the last *good* fix: a poor one can be 200 m off.
    final at = _lastGood;
    if (ix == null || at == null || s.legIndex >= s.journey.legs.length) {
      return null;
    }
    return riderVehicle(
        ix, vehicles.values, s.journey.legs[s.legIndex], at.lat, at.lon);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _stale?.cancel();
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (state != null) unawaited(_wake(false));
    super.dispose();
  }

  Future<void> _wake(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (e) {
      debugPrint('pm: wakelock failed: $e');
    }
  }
}

/// "Hai perso il 2?": the line names of the ride the rider seems to have
/// missed, or null. Set by the live trip, answered on the strip.
final missedRideProvider = StateProvider<String?>((ref) => null);

/// The change ahead that the live times say will not work, or null; set by
/// the live trip every few seconds while riding.
final connectionRiskProvider = StateProvider<ConnectionRisk?>((ref) => null);

final liveTripProvider =
    StateNotifierProvider<LiveTripController, LiveTripState?>(
      LiveTripController.new,
    );
