---
name: piedemove-routing
description: The routing engine — footpath generation, rRAPTOR, the every-line post-pass, filters, orderings, the balanced score, the departures helper, and how alerts change planning. Load when touching lib/routing, the golden test, or anything about journey results.
---

# Routing

Load `piedemove-data` alongside this for stop ids and index layout.

## Footpaths (§5.3)

Grid-bucket all stops, connect every pair within **400 m**.
`cost = haversine * 1.35 / walkSpeed`. Transfers must be transitively
consistent inside a cluster. Origin and destination coordinates get
access/egress edges to every stop within the walk cap, and that walking counts
toward the journey's walk metres.

Ceiling (name it in a comment): there is no pedestrian graph, so footpaths are
wrong across rail yards and the Po.

## Algorithm

**rRAPTOR** over a departure window. Label = `(arrivalTime, transfers,
walkMetres)` with a Pareto front. Up to 4 rides (3 transfers). Handle trips
started on the previous service day (times past 24:00). Minimum transfer time
is a setting.

## Every-line post-pass (§7.2)

RAPTOR returns a skeleton: board stop, alight stop, window. A post-pass scans
**every trip serving that stop pair inside the window** and collects the
distinct route short names. A leg then carries all of them (33 · 42 · 68), each
with its own next departure. This is the product's whole point — do not
collapse a leg to one route.

## Filters (§7.3)

Drop journeys that arrive later than `fastestArrival + maxExtraMinutes`, exceed
the walk cap, or use a **suspended** stop as board, alight or transfer.

## Orderings (§7.4)

- **Più veloce**: ascending arrival, ties by walk metres.
- **Bilanciato**: ascending score, ties by arrival.

## Score (§7.5)

    score = walkMetres + w * durationMinutes     // default w = 2

Walking dominates; time breaks near-ties. A detoured-line flag adds a flat
**150**. Define `score` as a **top-level function** imported by both the app and
the tests. If the §15 tests fail, tune `w` — never the test invariants.

## Departures helper (§7.6)

`nextDepartures(stop, when, n)` returns the next departures across all patterns
at a stop, merged with realtime, soonest first. It powers home "nearby
arrivals", the stop sheet, the line sheet and result cards. It must handle
today's *and* the previous day's trips.

## Alerts and planning (§8)

Alerts are parsed into an index by route, stop and trip. Suspended stops are
excluded by the planner. Detoured routes are kept but flagged and pay the 150
penalty. The results list shows a compact banner when active network alerts
exist, opening the full list.

## Tests (§15.1)

- `golden_politecnico_cristalliera_test` against the **real index**: POLITECNICO
  stop 3454 -> 45.0738, 7.6400, weekday ~18:00. Assert Bilanciato contains a
  journey alighting at TRAPANI (3693/3694), walking <= 200 m to PESCHIERA
  (230/241), riding line 2 to BARDONECCHIA (208/219); its walk metres strictly
  less than the Trapani-and-walk journey; the first leg's chips include both 33
  and 42. **Pin structure and stop ids, never exact times** — the feed
  regenerates daily.
- Ordering: Più veloce sorted by arrival; Bilanciato sorted by the real `score`;
  `fast.first.arrive <= balanced.first.arrive` and
  `balanced.first.walk <= fast.first.walk`.
- `tool/discover_hops.dart` scans many origin/destination pairs and lists cases
  where a footpath transfer between distinct stops cuts walking by >= 100 m
  versus the best no-footpath journey. Pin the top five as tests.
- `test/trips.yaml`: the user's own real trips as extra pass/fail cases.
- Units: footpath generation (the 126 m Trapani->Peschiera edge exists), RAPTOR
  on a tiny synthetic network, departures across midnight, delay propagation,
  stop clustering, alert matching, balanced-score ordering.

Routing is high-effort work. It must keep working with every live feed and the
whole line network unavailable.

## Built in phase 1

`lib/routing`: `footpaths.dart` (grid + CSR table + cluster closure),
`raptor.dart` (`Planner`, `PlanRequest`, `sortFastest`, `sortBalanced`),
`journey.dart`, `score.dart`, `departures.dart`. `tool/discover_hops.dart`
compares the real footpath table against a no-transfer baseline.

Decisions the code makes, with their ceilings:

- **Pareto front per number of rides.** Merging the rounds at the egress hides
  two-ride footpath answers behind three-ride chains that beat them on both
  arrival and metres. Bags are capped at 8 labels, walk-first.
- **One departure, not a range.** McRAPTOR runs once from the requested time;
  the window is used by the every-line post-pass. A later departure never walks
  less, so the front does not change. Upgrade to a real range search only if a
  missing journey is demonstrated.
- **No chained footpaths**: a label reached on foot cannot start another walk.
- Arrive-by runs one forward search from `deadline - window - 1 h` and keeps
  what lands in time.

### The golden case, as the real feed actually behaves (2026-09-19)

The spec's literal expectation does not hold, and the reasons are in the data:

- **No pattern from POLITECNICO pole 670 (`3454`) reaches TRAPANI.** Line 33
  leaves from pole 376 (`2829`), 30 m away, which the access walk covers.
- **Line 42 does not serve Politecnico at all** (its lines are 10, 33, 58, 91,
  W15), so "the first leg's chips include both 33 and 42" cannot ever pass.
- Line 2 towards BARDONECCHIA is boarded at PESCHIERA pole 121 (`241`), 155 m
  from TRAPANI 872 — not at pole 120 (`230`), which is the 126 m one.
- The literal TRAPANI -> PESCHIERA -> line 2 chain is genuinely dominated:
  boarding line 2 further upstream reaches BARDONECCHIA with 128 m of walking
  instead of 185 m, no later.

What the planner returns at 18:00 on a weekday: `10` -> walk 18 m -> `29` ->
walk 13 m -> `2` -> BARDONECCHIA, **233 m of walking**. Google's "33 then walk"
answer is in the same result set at **551 m**. Same intent as the golden case —
reach line 2 through short footpath hops instead of a long walk — but a better
journey, so `test/golden_politecnico_cristalliera_test.dart` pins that: the
126 m footpath exists in the table, the balanced best rides line 2 into
BARDONECCHIA using only transfers <= 200 m, it walks strictly less than the
ride-and-walk journey, and some ride leg carries more than one line.

`test/trips.yaml` holds the user's own trips (`name/from/to/at/maxWalk/maxRides`)
and is run by `test/trips_test.dart`. The §15 "pin the top five discovered
hops" step is still open: the wins shift with the daily feed, so they need
picking by hand from `dart tool/discover_hops.dart`.

## Built in phase 5 (wiring)

`PlanRequest.excludedRouteTypes` skips whole patterns in the round scan and in
the every-line post-pass, so a mode switched off in Settings never appears.
`lib/routing/providers.dart` holds `footpathsProvider` (built on the UI isolate
the first time something plans), `plannerProvider`, `suspendedStopsProvider`
(alert effect 1) and `detouredRoutesProvider` (effect 4), plus
`activeAlertsProvider` for the results banner.

## Built in phase 5b (real pedestrian routing)

Full detail in `docs/walk_routing.md`. Short version:

- Walking runs on the shipped/downloaded graph (`lib/geo/walk_*.dart`); every
  tunable number is in `walk_costs.dart`. `WalkRouter.route` gives polyline on
  real edges, true metres, maneuvers (start/turn/cross/steps/arrive, each with
  polyline index + metres); `WalkRouter.reroute(lat, lon, route)` re-plans from
  any position to the leg target (phase 6 consumes both).
- RAPTOR plans on estimates with the cap widened by `walkDetourFactor`;
  `routeWalks` (`lib/routing/walk_legs.dart`) re-prices every walk leg with
  routed metres/time, re-times missed rides, applies the real cap, then the
  lists are sorted, so displayed AND scored metres are routed ones.
- Lesson (found on the phone, not in tests): the RAPTOR label chain has no leg
  for the walk from the origin. `_buildJourney` now prepends it (fromStop -1);
  before, every journey silently omitted the access walk from metres and map.
  Tests that start AT a stop (the golden) cannot see this: keep one off-stop
  origin test (`routing_unit_test`).
- Lesson: `Isolate.run(() => ...)` written inside an async provider captures
  the async frame (a Future) and fails with "object is unsendable" on device
  only when the closure is built there; use a non-async helper (`_loadInIsolate`).
- On device (db4ae341, release): graph parse+grid ~360 ms once; plan ~190 ms;
  routeWalks 1-2 ms for 6-9 candidates.
