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

import 'package:flutter/services.dart';
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
import 'package:piedemove/ui/trip/trip_plan.dart';

/// Distances the rules turn on (§12), all metres.
const liveBoardRadius = 40.0;
const liveAlightRadius = 60.0;
const liveWalkEndRadius = 25.0;
const liveOnRouteCutoff = 60.0;
const liveOffRouteMetres = 150.0;
const livePoorAccuracy = 50.0;

const liveOffRouteFor = Duration(seconds: 30);
const liveNoFixFor = Duration(seconds: 20);

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
      final a = leg.fromStop >= 0
          ? (ix.stopLat[leg.fromStop], ix.stopLon[leg.fromStop])
          : (originLat == null || originLon == null
                ? null
                : (originLat, originLon));
      final b = leg.toStop >= 0
          ? (ix.stopLat[leg.toStop], ix.stopLon[leg.toStop])
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
/// [vehicleLat]/[vehicleLon] is the matched vehicle when one is known — used
/// to confirm boarding, and as the position of last resort when the fix is
/// poor. `walkSpeed` is the rider's own setting, in m/s.
LiveTripState advanceLive(
  LiveTripState s,
  LiveFix fix, {
  double? vehicleLat,
  double? vehicleLon,
  double walkSpeed = 1.2,
}) {
  if (s.finished) return s;
  var state = s.copyWith(lastFix: fix.at, clearCue: true);
  final leg = state.leg;

  var lat = fix.lat, lon = fix.lon;
  var estimated = false;
  if (fix.accuracy > livePoorAccuracy) {
    // Metro, tunnels, urban canyons: the vehicle beats a 200 m fix.
    if (vehicleLat != null && vehicleLon != null) {
      lat = vehicleLat;
      lon = vehicleLon;
    }
    estimated = true;
  }

  // Forward-only projection onto the segments from the last progress on.
  final proj = projectAhead(leg, lat, lon, state.along);
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
    if (stopsRemaining == 1 && s.stopsRemaining > 1) {
      state = _cue(state, LiveCue.oneStopLeft);
    } else if (stopsRemaining == 0 && s.stopsRemaining > 0) {
      state = _cue(state, LiveCue.alightNow);
    }
  }

  final boarding =
      leg.kind == LegKind.walk &&
      !state.isLastLeg &&
      state.route.legs[state.legIndex + 1].kind == LegKind.ride;
  final nearVehicle =
      vehicleLat != null &&
      vehicleLon != null &&
      haversineMetres(lat, lon, vehicleLat, vehicleLon) <= liveBoardRadius;
  final movingLikeAVehicle = fix.speed > walkSpeed * 1.6;

  final advance = switch (leg.kind) {
    LegKind.ride => straightToEnd <= liveAlightRadius,
    LegKind.walk =>
      boarding
          ? straightToEnd <= liveBoardRadius &&
                (nearVehicle || movingLikeAVehicle)
          : straightToEnd <= liveWalkEndRadius,
  };
  if (advance) return nextLeg(state);
  return state;
}

/// Result of [projectAhead].
typedef Projection = ({double along, double distance});

/// Projects (lat, lon) onto [leg]'s segments from [from] metres on, and
/// returns the nearest point's metres along the leg and its distance. Never
/// less than [from]: forward-only, so a fix behind the rider cannot rewind.
Projection projectAhead(LiveLeg leg, double lat, double lon, double from) {
  var bestAlong = from;
  var bestDist = double.infinity;
  final kx = math.cos(lat * math.pi / 180) * 111320.0, ky = 110540.0;
  for (var i = 0; i + 1 < leg.lat.length; i++) {
    if (leg.cumulative[i + 1] < from) continue;
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
  );
}

/// Marks the current leg done. Also the manual "Sono salito" / "Sono sceso".
LiveTripState nextLeg(LiveTripState s) {
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
  );
}

LiveTripState _cue(LiveTripState s, LiveCue cue) =>
    s.copyWith(cue: cue, cueSeq: s.cueSeq + 1);

/// No fix for 20 s: hold the position, estimate from the schedule, and label
/// it. Called on a timer, so a stalled GPS still shows an honest strip.
LiveTripState staleLive(
  LiveTripState s,
  DateTime now, {
  DateTime? serviceStart,
}) {
  final last = s.lastFix;
  if (s.finished || last == null || now.difference(last) < liveNoFixFor) {
    return s;
  }
  final leg = s.leg;
  var state = s.copyWith(estimated: true);
  if (serviceStart == null || leg.arrival <= leg.departure) return state;
  // Schedule-based estimate: linear along the leg between its two times.
  final elapsed =
      now.difference(serviceDayTime(serviceStart, leg.departure)).inSeconds;
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
    if (stopsRemaining == 1 && s.stopsRemaining > 1) {
      state = _cue(state, LiveCue.oneStopLeft);
    } else if (stopsRemaining == 0 && s.stopsRemaining > 0) {
      state = _cue(state, LiveCue.alightNow);
    }
  }
  return state;
}

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
  int _lastCueSeq = 0;
  LiveFix? _lastPos;

  /// The latest device fix, or null when none arrived yet.
  LiveFix? get lastFix => _lastPos;

  void start(Journey journey) {
    final ix = _ref.read(transitIndexProvider).valueOrNull;
    if (ix == null) return;
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
    WidgetsBinding.instance.addObserver(this);
    _listen();
    _stale = Timer.periodic(const Duration(seconds: 5), (_) => _onStale());
    unawaited(_wake(true));
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _stale?.cancel();
    _stale = null;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_wake(false));
    state = null;
  }

  /// "Sono salito" / "Sono sceso": always available, whatever the sensors say.
  void manualAdvance() {
    final s = state;
    if (s == null) return;
    final next = nextLeg(s);
    state = next;
    if (next.finished) stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (this.state == null) return;
    if (state == AppLifecycleState.resumed) {
      _listen();
      unawaited(_wake(true));
    } else {
      // Foreground only (§12): nothing listens while the app is away.
      _sub?.cancel();
      _sub = null;
      unawaited(_wake(false));
    }
  }

  void _listen() {
    if (_sub != null) return;
    try {
      _sub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 5,
            ),
          ).listen(
            _onFix,
            onError: (Object e) {
              debugPrint('pm: live position stream failed: $e');
            },
          );
    } catch (e) {
      debugPrint('pm: live position stream unavailable: $e');
    }
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
    _lastPos = LiveFix(
      lat: p.latitude,
      lon: p.longitude,
      accuracy: p.accuracy,
      speed: p.speed,
      at: DateTime.now(),
    );
    final vehicle = _vehicleFor(s);
    final next = advanceLive(
      s,
      LiveFix(
        lat: p.latitude,
        lon: p.longitude,
        accuracy: p.accuracy,
        speed: p.speed,
        at: DateTime.now(),
      ),
      vehicleLat: vehicle?.lat,
      vehicleLon: vehicle?.lon,
      walkSpeed: _ref.read(settingsProvider).walkSpeed,
    );
    _apply(next);
  }

  void _onStale() {
    final s = state;
    if (s == null) return;
    final date = s.journey.date;
    _apply(
      staleLive(
        s,
        DateTime.now(),
        serviceStart: DateTime(date.year, date.month, date.day),
      ),
    );
  }

  void _apply(LiveTripState next) {
    state = next;
    if (next.cue != null && next.cueSeq != _lastCueSeq) {
      _lastCueSeq = next.cueSeq;
      unawaited(HapticFeedback.vibrate());
    }
    if (next.finished) stop();
  }

  /// The live vehicle of the leg's own run, when the feed knows it.
  RtVehicle? _vehicleFor(LiveTripState s) {
    final tripId = s.leg.tripId;
    if (tripId == null) return null;
    final vehicles = _ref.read(realtimeProvider).vehicles;
    for (final v in vehicles.values) {
      if (v.tripId == tripId) return v;
    }
    return null;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _stale?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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

final liveTripProvider =
    StateNotifierProvider<LiveTripController, LiveTripState?>(
      LiveTripController.new,
    );
