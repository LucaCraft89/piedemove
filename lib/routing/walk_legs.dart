/// Walk legs of a planned journey: where they start and end, their routed
/// path and true distance.
///
/// RAPTOR prices a transfer as straight-line metres (a footpath table has to
/// be precomputed for every stop pair, and routing 100k pairs on a phone is
/// not free). So it proposes candidates with estimates, and this pass, which
/// runs on the few journeys it returns, replaces every walk leg's distance by
/// the router's true one, re-times the journey, and drops what no longer fits.
/// docs/walk_routing.md, "Planning vs routing".
library;

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/walk_costs.dart';
import 'package:piedemove/geo/walk_router.dart';

import 'footpaths.dart';
import 'journey.dart';

/// Both ends `(lat, lon)` of a walk leg: a stop's coordinate, or the query's
/// origin/destination for the off-stop end. Null when one is unknown. The one
/// place that decides this, shared by drawing, routing and live trips.
((double, double), (double, double))? walkLegEnds(
  TransitIndex ix,
  Leg leg, {
  (double, double)? origin,
  (double, double)? destination,
}) {
  final a = leg.fromStop >= 0
      ? (ix.stopLat[leg.fromStop], ix.stopLon[leg.fromStop])
      : origin;
  final b = leg.toStop >= 0
      ? (ix.stopLat[leg.toStop], ix.stopLon[leg.toStop])
      : destination;
  return a == null || b == null ? null : (a, b);
}

/// A ride whose departure the real walk overshoots by no more than this is kept
/// as planned: timetable seconds are not that exact, and the planner itself
/// allows a zero-second buffer after a footpath. Longer overshoots re-board.
const walkConnectionGraceSeconds = 30;

/// Memoised routing between coordinate pairs (a journey list repeats the same
/// transfers, and re-selecting a journey must be instant).
class WalkRoutes {
  WalkRoutes(this.router);
  final WalkRouter router;
  final _cache = <String, WalkRoute?>{};

  WalkRoute? route(double aLat, double aLon, double bLat, double bLon) {
    final key = '${aLat.toStringAsFixed(5)},${aLon.toStringAsFixed(5)},'
        '${bLat.toStringAsFixed(5)},${bLon.toStringAsFixed(5)}';
    if (_cache.containsKey(key)) return _cache[key];
    if (_cache.length > 2000) _cache.clear();
    return _cache[key] = router.route(aLat, aLon, bLat, bLon);
  }
}

/// Re-prices every walk leg with the routed distance and re-times the journey
/// around it: the real walk is often longer than the estimate (a stop across
/// the road is a crossing away), so a ride the traveller can no longer catch is
/// re-boarded on the next departure ([retime]) rather than the journey being
/// thrown away. What still exceeds [capMetres] once walked properly, or
/// arrives more than [maxExtraSeconds] after the best, is dropped. Without a
/// router, or where the graph does not cover a leg, the planner's estimate is
/// scaled by [walkDetourFactor] and the leg stays unrouted (shown with "≈").
List<Journey> routeWalks(
  List<Journey> journeys,
  TransitIndex ix,
  WalkRoutes? routes, {
  required (double, double) origin,
  required (double, double) destination,
  required double capMetres,
  double walkSpeed = walkSpeedMetresPerSecond,
  Leg? Function(Leg ride, int readyTime, DateTime date)? retime,
  int? maxExtraSeconds,
}) {
  final out = <Journey>[];
  for (final j in journeys) {
    final legs = <Leg>[];
    var ok = true;
    var t = j.legs.first.departure; // where and when the traveller is
    for (var i = 0; i < j.legs.length && ok; i++) {
      final leg = j.legs[i];
      if (leg.kind == LegKind.ride) {
        if (leg.departure + walkConnectionGraceSeconds >= t) {
          legs.add(leg);
          t = leg.arrival;
        } else {
          final again = retime?.call(leg, t, j.date);
          if (again == null) {
            ok = false; // the real walk misses it and nothing follows
          } else {
            legs.add(again);
            t = again.arrival;
          }
        }
        continue;
      }
      final ends = walkLegEnds(ix, leg, origin: origin, destination: destination);
      final route = ends == null || routes == null
          ? null
          : routes.route(ends.$1.$1, ends.$1.$2, ends.$2.$1, ends.$2.$2);
      final departure = i == 0 ? leg.departure : t;
      if (route == null) {
        final metres = leg.walkMetres * walkDetourFactor;
        final secs = (metres / walkSpeed).round();
        legs.add(leg.withWalk(
            walkMetres: metres, departure: departure, arrival: departure + secs));
        t = departure + secs;
      } else {
        final secs = (route.metres / walkSpeed).round();
        legs.add(leg.withWalk(
            walkMetres: route.metres,
            departure: departure,
            arrival: departure + secs,
            route: route));
        t = departure + secs;
      }
    }
    if (!ok) continue;
    final routed = Journey(legs, j.date);
    if (routed.walkMetres <= capMetres) out.add(routed);
  }
  if (maxExtraSeconds != null && out.isNotEmpty) {
    final fastest = out.map((j) => j.arrival).reduce((a, b) => a < b ? a : b);
    out.removeWhere((j) => j.arrival > fastest + maxExtraSeconds);
  }
  return out;
}
