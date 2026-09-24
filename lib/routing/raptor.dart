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

bool _addToBag(List<_Label> bag, _Label candidate) {
  for (final l in bag) {
    if (l.arrival <= candidate.arrival && l.walk <= candidate.walk) return false;
  }
  bag.removeWhere(
      (l) => candidate.arrival <= l.arrival && candidate.walk <= l.walk);
  bag.add(candidate);
  if (bag.length > _bagCap) {
    bag.sort((a, b) => a.walk != b.walk
        ? a.walk.compareTo(b.walk)
        : a.arrival.compareTo(b.arrival));
    bag.removeRange(_bagCap, bag.length);
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
    final todayIdx = ix.dayIndexOf(date);
    final startSeconds =
        req.when.hour * 3600 + req.when.minute * 60 + req.when.second;
    // ponytail: arrive-by runs one forward search from `deadline - window` and
    // keeps what lands in time. Upgrade to a backward search if the window
    // proves too narrow.
    final departAt = req.arriveBy
        ? startSeconds - req.windowMinutes * 60 - 3600
        : startSeconds;

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
              readyTime: a.label.arrival,
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
              final aDep = ix.depOf(a.trip, a.boardPos) + a.offset;
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
    if (finals.isEmpty) return const [];

    var journeys = finals
        .map((l) => _buildJourney(l, date, req))
        .toList();

    // ---- filters (§7.3) --------------------------------------------------
    final fastest =
        journeys.map((j) => j.arrival).reduce(math.min);
    journeys = journeys
        .where((j) =>
            j.arrival <= fastest + req.maxExtraMinutes * 60 &&
            j.walkMetres <= req.walkCapMetres)
        .toList();
    if (req.arriveBy) {
      journeys = journeys.where((j) => j.arrival <= startSeconds).toList();
    }
    return _dedupe(journeys);
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
  /// as (trip, dayOffsetSeconds, effectiveDeparture). Considers today's
  /// services and trips that started the previous service day (times >= 24:00).
  (int, int, int)? _earliestTrip(
      int pattern, int pos, int minTime, int todayIdx) {
    (int, int, int)? best;
    for (final (dayIdx, offset) in [
      (todayIdx, 0),
      (todayIdx - 1, -secondsPerDay),
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
      for (var i = lo; i < count; i++) {
        final trip = ix.patternTripAt(pattern, i);
        final dep = ix.depOf(trip, pos);
        if (dep < want) continue;
        if (!ix.serviceRunsOn(ix.tripService[trip], dayIdx)) continue;
        final eff = dep + offset;
        if (best == null || eff < best.$3) best = (trip, offset, eff);
        break;
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
    final byRoute = <String, RideOption>{};
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
      final existing = byRoute[name];
      if (existing == null || option.departure < existing.departure) {
        byRoute[name] = option;
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
