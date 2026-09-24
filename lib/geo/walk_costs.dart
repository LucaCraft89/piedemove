/// The pedestrian cost model, in one place (docs/walk_routing.md explains it).
///
/// The graph stores *what an edge is* (kind, sub-kind, sidewalk state,
/// crossing type, covered); this file decides *what it costs*. Tuning a
/// number here never needs a graph rebuild.
///
/// Cost is in "equivalent metres": the true length times a factor, plus a fixed
/// amount for crossings. The distance shown to the user is always the true
/// length; the cost only decides which path is chosen.
library;

import 'walk_graph.dart';

/// Walking speed behind every displayed walking time.
const walkSpeedMetresPerSecond = 1.2;

// -- crossings: controlled < zebra / uncontrolled < unmarked ----------------
/// Signals: a wait, but the safest and the one people accept.
const crossSignalsMetres = 20.0;
const crossZebraMetres = 25.0;
const crossUncontrolledMetres = 30.0;

/// Nothing marks it: heavily penalised, used so the graph never disconnects.
const crossUnmarkedMetres = 120.0;

// -- edge factors -----------------------------------------------------------
const stepsFactor = 3.0;
const coveredFactor = 0.9;

/// Dedicated ways: generic path, mapped sidewalk, pedestrian zone, rough track.
const pathFactors = [1.0, 1.0, 0.95, 1.3];

/// Minor streets walked on the carriageway: residential, living street,
/// service lane / parking aisle.
const streetFactors = [1.0, 0.95, 1.3];

/// Sidewalk of a busy road, by road class (tertiary, secondary, primary+) and
/// by what OSM says about that side (unknown, present, none): the road's
/// proximity is priced here.
const sideFactors = [
  [1.15, 1.0, 1.6],
  [1.25, 1.05, 2.0],
  [1.4, 1.1, 2.5],
];

/// Smallest factor anywhere: keeps the A* heuristic admissible.
const minWalkFactor = 0.9;

double crossingMetres(int type) => switch (type) {
      WalkCrossing.signals => crossSignalsMetres,
      WalkCrossing.zebra => crossZebraMetres,
      WalkCrossing.uncontrolled => crossUncontrolledMetres,
      _ => crossUnmarkedMetres,
    };

/// Search cost of an edge of [metres] with the given [flags].
double walkEdgeCost(int flags, double metres) {
  final kind = WalkFlags.kind(flags), sub = WalkFlags.sub(flags);
  var factor = 1.0;
  var fixed = 0.0;
  switch (kind) {
    case WalkKind.path:
      factor = pathFactors[sub];
    case WalkKind.street:
      factor = streetFactors[sub.clamp(0, 2)];
    case WalkKind.side:
      factor = sideFactors[sub.clamp(0, 2)][WalkFlags.sidewalk(flags).clamp(0, 2)];
    case WalkKind.steps:
      factor = stepsFactor;
    case WalkKind.crossing:
      fixed = crossingMetres(sub);
  }
  if (WalkFlags.covered(flags)) factor *= coveredFactor;
  return metres * factor + fixed;
}
