/// Multicriteria RAPTOR over (arrival, walk metres), plus the every-line
/// post-pass that turns each ride leg into the full list of lines that can make
/// the hop.
///
/// Rides are free for the user, so walking metres are the real cost: the Pareto
/// front is kept on (arrival, walkMetres) and never collapsed to arrival alone.
library;

import 'dart:math' as math;

import 'package:piedemove/data/transit_index.dart';

import 'footpaths.dart';
import 'journey.dart';
import 'score.dart';

const secondsPerDay = 86400;

class PlanRequest {
  const PlanRequest({
    required this.originLat,
    required this.originLon,
    required this.destLat,
    required this.destLon,
    required this.when,
    this.arriveBy = false,
    this.walkCapMetres = 800,
    this.walkSpeed = defaultWalkSpeed,
    this.maxTransfers = 3,
    this.minTransferSeconds = 60,
    this.maxExtraMinutes = 20,
    this.windowMinutes = 60,
    this.suspendedStops = const <int>{},
    this.excludedRouteTypes = const <int>{},
    this.detouredRoutes = const <int>{},
  });

  PlanRequest withWalkCap(double cap) => PlanRequest(
        originLat: originLat,
        originLon: originLon,
        destLat: destLat,
        destLon: destLon,
        when: when,
        arriveBy: arriveBy,
        walkCapMetres: cap,
        walkSpeed: walkSpeed,
        maxTransfers: maxTransfers,
        minTransferSeconds: minTransferSeconds,
        maxExtraMinutes: maxExtraMinutes,
        windowMinutes: windowMinutes,
        suspendedStops: suspendedStops,
        excludedRouteTypes: excludedRouteTypes,
        detouredRoutes: detouredRoutes,
      );

  final double originLat;
  final double originLon;
  final double destLat;
  final double destLon;

  /// Depart-after time, or the arrive-by deadline when [arriveBy].
  final DateTime when;
  final bool arriveBy;
  final double walkCapMetres;
  final double walkSpeed;
  final int maxTransfers;
  final int minTransferSeconds;
  final int maxExtraMinutes;
  final int windowMinutes;
  final Set<int> suspendedStops;

  /// GTFS `route_type`s the user switched off in Settings (§11.7).
  final Set<int> excludedRouteTypes;
  final Set<int> detouredRoutes;
}

class _Label {
  _Label({
    required this.arrival,
    required this.walk,
    required this.stop,
    this.prev,
    this.ride = false,
    this.pattern = -1,
    this.trip = -1,
    this.boardStop = -1,
    this.boardTime = 0,
    this.readyTime = 0,
  });

  final int arrival;
  final double walk;
  final int stop;
  final _Label? prev;
  final bool ride;
  final int pattern;
  final int trip;
  final int boardStop;
  final int boardTime;
  final int readyTime;
}

class _Active {
  _Active(this.trip, this.offset, this.label, this.boardPos, this.boardTime);
  final int trip;
  final int offset;
  final _Label label;
  final int boardPos;
  final int boardTime;
}

const _bagCap = 8;

/// Arrive-by searches start this long before `deadline - window`, so a long
/// journey that must leave early is still inside the first pass.
const arriveByLookbackSeconds = 3600;

/// Upper bound on arrive-by forward passes (each is one full search).
const arriveByMaxPasses = 8;

/// Arrive-by: the access walk is timed to reach the first stop this early.
const arriveByBoardBufferSeconds = 120;

/// Trips of a pattern are sorted by first-stop departure; overtaking can make
/// a later-sorted trip leave an intermediate stop first. The trip lookup scans
/// this many neighbours around the binary-search hit to catch it.
const _overtakeScan = 4;

bool _addToBag(List<_Label> bag, _Label candidate) {
  for (final l in bag) {
    if (l.arrival <= candidate.arrival && l.walk <= candidate.walk) return false;
  }
  bag.removeWhere(
      (l) => candidate.arrival <= l.arrival && candidate.walk <= l.walk);
  bag.add(candidate);
  if (bag.length > _bagCap) {
    // A full bag is a Pareto front: ascending walk means descending arrival.
    // Keep both extremes (least walk, earliest arrival) and drop the interior
    // label closest in walk to its lower neighbour - the most redundant one.
    bag.sort((a, b) => a.walk != b.walk
        ? a.walk.compareTo(b.walk)
        : a.arrival.compareTo(b.arrival));
    var drop = 1;
    for (var i = 2; i < bag.length - 1; i++) {
      if (bag[i].walk - bag[i - 1].walk <
          bag[drop].walk - bag[drop - 1].walk) {
        drop = i;
      }
    }
    if (identical(bag.removeAt(drop), candidate)) return false;
  }
  return true;
}

class Planner {
  Planner(this.ix, this.footpaths);

  final TransitIndex ix;
  final Footpaths footpaths;

  /// Plans journeys, ordered by the caller (see [sortFastest] /
  /// [sortBalanced]). Returns an empty list when nothing is reachable.
  List<Journey> plan(PlanRequest req) {
    final date = DateTime(req.when.year, req.when.month, req.when.day);
    final startSeconds =
        req.when.hour * 3600 + req.when.minute * 60 + req.when.second;
    if (req.arriveBy) return _dedupe(_arriveBy(req, date, startSeconds));

    var journeys = _search(req, date, startSeconds);
    if (journeys.isEmpty) return const [];
    // ---- filters (§7.3) --------------------------------------------------
    final fastest = journeys.map((j) => j.arrival).reduce(math.min);
    journeys = journeys
        .where((j) =>
            j.arrival <= fastest + req.maxExtraMinutes * 60 &&
            j.walkMetres <= req.walkCapMetres)
        .toList();
    return _dedupe(journeys);
  }

  /// Arrive-by: forward searches from successively later departures, so the
  /// answer leaves as late as it can and still lands by [deadline]. Each pass
  /// starts just after the latest moment the previous pass's earliest option
  /// could be left for, which moves it on to the next boarding.
  List<Journey> _arriveBy(PlanRequest req, DateTime date, int deadline) {
    final found = <Journey>[];
    var from = deadline - req.windowMinutes * 60 - arriveByLookbackSeconds;
    for (var pass = 0; pass < arriveByMaxPasses && from < deadline; pass++) {
      final fits = [
        for (final j in _search(req, date, from))
          if (j.arrival <= deadline && j.walkMetres <= req.walkCapMetres) j,
      ];
      if (fits.isEmpty) break;
      found.addAll(fits.map(_leaveLate));
      // Leaving one second after the last moment that still catches the
      // earliest first ride found forces the next pass onto a later one.
      from = fits.map(_lastLeave).reduce(math.min) + 1;
    }
    if (found.isEmpty) return const [];
    // Later departure, less walking and fewer rides are all better; keep
    // what no other option beats on all three.
    final front = [
      for (final j in found)
        if (!found.any((k) =>
            !identical(k, j) &&
            k.departure >= j.departure &&
            k.walkMetres <= j.walkMetres &&
            k.rides <= j.rides &&
            (k.departure > j.departure ||
                k.walkMetres < j.walkMetres ||
                k.rides < j.rides)))
          j,
    ];
    final latest = front.map((j) => j.departure).reduce(math.max);
    return front
        .where((j) => j.departure >= latest - req.maxExtraMinutes * 60)
        .toList();
  }

  /// Moves the walking before the first ride as late as that ride allows
  /// (keeping [arriveByBoardBufferSeconds] at the stop), so "leave at" is
  /// honest.
  Journey _leaveLate(Journey j) {
    final r = j.legs.indexWhere((l) => l.kind == LegKind.ride);
    if (r <= 0) return j;
    final slack =
        j.legs[r].departure - arriveByBoardBufferSeconds - j.legs[r - 1].arrival;
    if (slack <= 0) return j;
    return Journey([
      for (var i = 0; i < j.legs.length; i++)
        i < r
            ? j.legs[i].withWalk(
                walkMetres: j.legs[i].walkMetres,
                departure: j.legs[i].departure + slack,
                arrival: j.legs[i].arrival + slack,
                route: j.legs[i].route,
              )
            : j.legs[i],
    ], j.date);
  }

  /// The latest departure from the origin that still reaches the first ride.
  static int _lastLeave(Journey j) {
    final r = j.legs.indexWhere((l) => l.kind == LegKind.ride);
    if (r <= 0) return j.departure;
    return j.legs[r].departure - (j.legs[r - 1].arrival - j.departure);
  }

  /// One forward multicriteria search leaving at [departAt]; every
  /// non-dominated journey, unfiltered.
  List<Journey> _search(PlanRequest req, DateTime date, int departAt) {
    final todayIdx = ix.dayIndexOf(date);
    final access = footpaths.grid
        .near(req.originLat, req.originLon, req.walkCapMetres)
        .where((e) => !req.suspendedStops.contains(e.$1))
        .toList();
    final egress = footpaths.grid
        .near(req.destLat, req.destLon, req.walkCapMetres)
        .where((e) => !req.suspendedStops.contains(e.$1))
        .toList();
    if (access.isEmpty || egress.isEmpty) return const [];

    final rounds = req.maxTransfers + 1;
    final bags = List.generate(
        rounds + 1, (_) => List.generate(ix.stopCount, (_) => <_Label>[]));

    var marked = <int>{};
    for (final (stop, metres) in access) {
      final label = _Label(
        arrival: departAt + walkSeconds(metres, walkSpeed: req.walkSpeed),
        walk: metres,
        stop: stop,
      );
      if (_addToBag(bags[0][stop], label)) marked.add(stop);
    }
    marked = _relaxFootpaths(bags[0], marked, req);

    for (var round = 1; round <= rounds; round++) {
      if (marked.isEmpty) break;
      final patternStart = <int, int>{};
      for (final stop in marked) {
        for (var i = ix.stopPatternOffset[stop];
            i < ix.stopPatternOffset[stop + 1];
            i++) {
          final p = ix.stopPattern[i];
          final pos = ix.stopPatternPos[i];
          final cur = patternStart[p];
          if (cur == null || pos < cur) patternStart[p] = pos;
        }
      }

      final newlyMarked = <int>{};
      patternStart.forEach((pattern, startPos) {
        if (req.excludedRouteTypes.contains(ix.routeTypeOfPattern(pattern))) {
          return;
        }
        final active = <_Active>[];
        final length = ix.patternLength(pattern);
        for (var pos = startPos; pos < length; pos++) {
          final stop = ix.patternStopAt(pattern, pos);
          final suspended = req.suspendedStops.contains(stop);

          for (final a in active) {
            if (suspended) continue;
            final arrival = ix.arrOf(a.trip, pos) + a.offset;
            final label = _Label(
              arrival: arrival,
              walk: a.label.walk,
              stop: stop,
              prev: a.label,
              ride: true,
              pattern: pattern,
              trip: a.trip,
              boardStop: ix.patternStopAt(pattern, a.boardPos),
              boardTime: a.boardTime,
              // Same buffer the search boarded with, so the every-line pass
              // never lists a connection the planner deems impossible.
              readyTime: a.label.arrival +
                  (a.label.ride ? req.minTransferSeconds : 0),
            );
            if (_addToBag(bags[round][stop], label)) newlyMarked.add(stop);
          }

          if (suspended) continue;
          for (final label in bags[round - 1][stop]) {
            final ready = label.arrival +
                (label.ride ? req.minTransferSeconds : 0);
            final found = _earliestTrip(pattern, pos, ready, todayIdx);
            if (found == null) continue;
            final (trip, offset, departure) = found;
            var dominated = false;
            active.removeWhere((a) {
              // Both trips compared where they both are: at this stop.
              final aDep = ix.depOf(a.trip, pos) + a.offset;
              if (departure <= aDep && label.walk <= a.label.walk) return true;
              if (aDep <= departure && a.label.walk <= label.walk) {
                dominated = true;
              }
              return false;
            });
            if (!dominated) {
              active.add(_Active(trip, offset, label, pos, departure));
            }
          }
        }
      });

      marked = _relaxFootpaths(bags[round], newlyMarked, req);
    }

    // ---- egress ---------------------------------------------------------
    // The Pareto front is kept **per number of rides**. Merging the rounds here
    // would hide the answer the product exists for: a two-ride journey that
    // uses a short footpath is often beaten on both arrival and metres by some
    // three-ride chain, and would disappear from the list.
    final finals = <_Label>[];
    for (var round = 0; round <= rounds; round++) {
      final roundFinals = <_Label>[];
      for (final (stop, metres) in egress) {
        for (final label in bags[round][stop]) {
          if (!label.ride) continue; // walking-only trips are not offered
          final walk = label.walk + metres;
          if (walk > req.walkCapMetres) continue;
          _addToBag(
            roundFinals,
            _Label(
              arrival:
                  label.arrival + walkSeconds(metres, walkSpeed: req.walkSpeed),
              walk: walk,
              stop: -1,
              prev: label,
            ),
          );
        }
      }
      finals.addAll(roundFinals);
    }
    return [for (final l in finals) _buildJourney(l, date, req)];
  }

  Set<int> _relaxFootpaths(
      List<List<_Label>> bag, Set<int> marked, PlanRequest req) {
    final out = Set<int>.from(marked);
    for (final stop in marked) {
      for (var i = footpaths.offset[stop]; i < footpaths.offset[stop + 1]; i++) {
        final target = footpaths.target[i];
        if (req.suspendedStops.contains(target)) continue;
        final metres = footpaths.metres[i];
        for (final label in List<_Label>.from(bag[stop])) {
          if (label.stop != stop || !_isAtStop(label, stop)) continue;
          final walk = label.walk + metres;
          if (walk > req.walkCapMetres) continue;
          final candidate = _Label(
            arrival:
                label.arrival + walkSeconds(metres, walkSpeed: req.walkSpeed),
            walk: walk,
            stop: target,
            prev: label,
          );
          if (_addToBag(bag[target], candidate)) out.add(target);
        }
      }
    }
    return out;
  }

  /// Re-boards a ride leg for a traveller who can only be at its board stop at
  /// [readyTime] (the real walk took longer than the planner assumed): the
  /// earliest arrival among the lines that make the hop from then on, or null
  /// when none does inside the window.
  Leg? retimeRide(Leg leg, int readyTime, PlanRequest req, DateTime date) {
    final options = _lineOptions(leg.fromStop, leg.toStop, readyTime, date, req);
    if (options.isEmpty) return null;
    final best = options.reduce((a, b) => a.arrival <= b.arrival ? a : b);
    return Leg(
      kind: LegKind.ride,
      fromStop: leg.fromStop,
      toStop: leg.toStop,
      departure: best.departure,
      arrival: best.arrival,
      readyTime: readyTime,
      options: options,
    );
  }

  // A label reached by walking is not a base for another walk: no chained
  // footpaths, which would otherwise wander across the city.
  bool _isAtStop(_Label label, int stop) =>
      label.stop == stop && (label.ride || label.prev == null);

  /// Earliest trip of [pattern] departing position [pos] at or after [minTime],
  /// as (trip, dayOffsetSeconds, effectiveDeparture). Considers the previous
  /// service day (trips past 24:00), today, and - once [minTime] itself is past
  /// midnight - the next service day.
  (int, int, int)? _earliestTrip(
      int pattern, int pos, int minTime, int todayIdx) {
    (int, int, int)? best;
    for (final (dayIdx, offset) in [
      (todayIdx - 1, -secondsPerDay),
      (todayIdx, 0),
      if (minTime >= secondsPerDay) (todayIdx + 1, secondsPerDay),
    ]) {
      if (dayIdx < 0 || dayIdx >= ix.serviceDayCount) continue;
      final want = minTime - offset;
      final count = ix.patternTripCount(pattern);
      var lo = 0, hi = count;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (ix.depOf(ix.patternTripAt(pattern, mid), pos) < want) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      // Trips are sorted at the first stop, not here: look a few either side
      // of the hit, and a few past the first match, for an overtaking trip.
      var stopAt = count;
      for (var i = math.max(0, lo - _overtakeScan); i < stopAt; i++) {
        final trip = ix.patternTripAt(pattern, i);
        final dep = ix.depOf(trip, pos);
        if (dep < want) continue;
        if (!ix.serviceRunsOn(ix.tripService[trip], dayIdx)) continue;
        final eff = dep + offset;
        if (best == null || eff < best.$3) best = (trip, offset, eff);
        if (stopAt == count) stopAt = math.min(count, i + 1 + _overtakeScan);
      }
    }
    return best;
  }

  Journey _buildJourney(_Label finalLabel, DateTime date, PlanRequest req) {
    final chain = <_Label>[];
    for (_Label? l = finalLabel; l != null; l = l.prev) {
      chain.add(l);
    }
    final ordered = chain.reversed.toList();
    final legs = <Leg>[];
    for (var i = 1; i < ordered.length; i++) {
      final l = ordered[i];
      final from = ordered[i - 1];
      if (l.ride) {
        legs.add(Leg(
          kind: LegKind.ride,
          fromStop: l.boardStop,
          toStop: l.stop,
          departure: l.boardTime,
          arrival: l.arrival,
          readyTime: l.readyTime,
          options: _lineOptions(
              l.boardStop, l.stop, l.readyTime, date, req),
        ));
      } else {
        legs.add(Leg(
          kind: LegKind.walk,
          fromStop: from.stop,
          toStop: l.stop,
          departure: from.arrival,
          arrival: l.arrival,
          walkMetres: l.walk - from.walk,
        ));
      }
    }
    // Two rides meeting at one stop with no walk between (e.g. M1 > M1, or line
    // 2 | line 2 on another trip) are one ride when a single line covers the
    // whole hop: merge, at the shared stop.
    for (var i = 1; i < legs.length;) {
      final a = legs[i - 1], b = legs[i];
      if (a.kind == LegKind.ride && b.kind == LegKind.ride) {
        final opts =
            _lineOptions(a.fromStop, b.toStop, a.readyTime, date, req);
        if (opts.isNotEmpty &&
            opts.any((o) => o.arrival <= b.arrival + 60)) {
          final best = opts.reduce((x, y) => x.arrival <= y.arrival ? x : y);
          legs[i - 1] = Leg(
            kind: LegKind.ride,
            fromStop: a.fromStop,
            toStop: b.toStop,
            departure: best.departure,
            arrival: best.arrival,
            readyTime: a.readyTime,
            options: opts,
          );
          legs.removeAt(i);
          continue;
        }
      }
      i++;
    }
    // The access walk starts at the origin, which is not a stop. It is the
    // seed label's own walk, so no label chain leg carries it: add it here.
    final seed = ordered.first;
    if (seed.walk > 0) {
      final secs = walkSeconds(seed.walk, walkSpeed: req.walkSpeed);
      legs.insert(
          0,
          Leg(
            kind: LegKind.walk,
            fromStop: -1,
            toStop: seed.stop,
            departure: seed.arrival - secs,
            arrival: seed.arrival,
            walkMetres: seed.walk,
          ));
    }
    if (legs.isNotEmpty && legs.last.kind == LegKind.walk) {
      final f = legs.last;
      legs[legs.length - 1] = Leg(
        kind: LegKind.walk,
        fromStop: f.fromStop,
        toStop: -1,
        departure: f.departure,
        arrival: f.arrival,
        walkMetres: f.walkMetres,
      );
    }
    return Journey(legs, date);
  }

  /// Every-line post-pass (§7.2): every line that can carry the traveller from
  /// [boardStop] to [alightStop] inside the window, each with its own next
  /// departure. A leg is never collapsed to a single route.
  List<RideOption> _lineOptions(
      int boardStop, int alightStop, int readyTime, DateTime date,
      PlanRequest req) {
    final todayIdx = ix.dayIndexOf(date);
    final windowEnd = readyTime + req.windowMinutes * 60;
    // Keyed by feed and number: regional "2" is not GTT tram 2.
    final byRoute = <(int, String), RideOption>{};
    for (var i = ix.stopPatternOffset[boardStop];
        i < ix.stopPatternOffset[boardStop + 1];
        i++) {
      final pattern = ix.stopPattern[i];
      if (req.excludedRouteTypes.contains(ix.routeTypeOfPattern(pattern))) {
        continue;
      }
      final boardPos = ix.stopPatternPos[i];
      var alightPos = -1;
      for (var pos = boardPos + 1; pos < ix.patternLength(pattern); pos++) {
        if (ix.patternStopAt(pattern, pos) == alightStop) {
          alightPos = pos;
          break;
        }
      }
      if (alightPos < 0) continue;
      final found = _earliestTrip(pattern, boardPos, readyTime, todayIdx);
      if (found == null) continue;
      final (trip, offset, departure) = found;
      if (departure > windowEnd) continue;
      final route = ix.patternRoute[pattern];
      final name = ix.routeShortNames[route];
      final option = RideOption(
        routeShortName: name,
        routeType: ix.routeTypes[route],
        pattern: pattern,
        trip: trip,
        departure: departure,
        arrival: ix.arrOf(trip, alightPos) + offset,
        detoured: req.detouredRoutes.contains(route),
        scheduledOnly: ix.isScheduledOnly(route),
      );
      final key = (ix.routeFeed[route], name);
      final existing = byRoute[key];
      if (existing == null || option.departure < existing.departure) {
        byRoute[key] = option;
      }
    }
    final options = byRoute.values.toList()
      ..sort((a, b) => a.departure.compareTo(b.departure));
    return options;
  }

  List<Journey> _dedupe(List<Journey> journeys) {
    final seen = <String>{};
    final out = <Journey>[];
    for (final j in journeys) {
      final key = j.legs
          .map((l) => '${l.kind.index}:${l.fromStop}>${l.toStop}:${l.departure}')
          .join('|');
      if (seen.add(key)) out.add(j);
    }
    return out;
  }
}

/// Più veloce: ascending arrival, ties by walk metres.
List<Journey> sortFastest(List<Journey> journeys) => journeys.toList()
  ..sort((a, b) => a.arrival != b.arrival
      ? a.arrival.compareTo(b.arrival)
      : a.walkMetres.compareTo(b.walkMetres));

/// Bilanciato: ascending [score], ties by arrival.
List<Journey> sortBalanced(List<Journey> journeys) {
  double s(Journey j) => score(
        walkMetres: j.walkMetres,
        durationMinutes: j.durationSeconds / 60,
        detoured: j.detoured,
      );
  return journeys.toList()
    ..sort((a, b) =>
        s(a) != s(b) ? s(a).compareTo(s(b)) : a.arrival.compareTo(b.arrival));
}
