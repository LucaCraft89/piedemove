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
