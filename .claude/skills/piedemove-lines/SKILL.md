---
name: piedemove-lines
description: Road/tram graph, snapping patterns to streets, the merged ambient line network, arrows, connectors, focus mode, walking lines, travelled-vs-ahead, and the line validation report. Load for anything in lib/geo, any map line geometry, or phase 6. Read the Lessons section first - each rule exists because a previous attempt failed.
---

# Lines (§9) — rewritten from scratch

Its own module (`lib/geo/`) with its own cache file, so a failure here never
affects routing. Copy nothing from `../piemove-maps`. High-effort work.

## Lessons — why each rule exists

1. Slicing a route by **nearest-vertex search** picks the wrong pass on loops
   and makes ends collide. -> Record the **path vertex index of every stop at
   build time** and slice by index, never by projection.
2. Reusing one direction's shape **reversed** draws the wrong carriageway on
   divided roads. -> Directed graph, each pattern routed in its own direction.
3. Pedestrian and service ways in the bus graph cause off-road jogs and
   shortcuts. -> Filtered graph.
4. "Same road" decided by a **distance guess** (grid cells, tolerances) merged
   unrelated lines. -> Merge by **shared OSM way identity**, same mode only.
5. GeoJSON features without a **top-level numeric `id`** silently render nothing
   on Android. -> Every feature carries one.
6. **Array-valued** feature properties are unreliable to query back. ->
   Comma-separated strings and numbers only.
7. One layer failing blanked everything. -> Each layer added in its own
   try/catch, plus a visible feed-health indicator.
8. Stops snapped to the `service=parking_aisle` way beside the kerb, and
   routing (which refuses service ways mid-route) then had nowhere to go: 2802
   dead hops. -> Aisles and driveways are out of the graph, and a stop never
   snaps to a service edge while a road edge is in reach.
9. Heading alone cannot tell a main carriageway from its controviale. -> The
   stop-snap score adds the candidate's distance to the pattern's GTFS shape.
   Chorded hops fell 10.3% -> 3.6% from lessons 8 and 9 together.
10. Overpass times out (504) on a regex over `highway` values, and answers in
   ~2 s for the bare `way["highway"]` key; `overpass.osm.ch` holds Switzerland
   only and answers **200 with an empty element list**. -> Bare key query,
   local filtering in `wayInMode`, and a tile shorter than 2 KB counts as a
   miss, not as an empty area.

## Build

    dart tool/build_lines.dart [--force-osm] [--reverse]   # -> build/lines.bin
    dart tool/lines_report.dart [--full]                   # 9.12 validation
    dart tool/gate1_samples.dart                           # GATE 2 sample spots

Tiles are cached gzipped in `build/osm/`. Two processes (the second with
`--reverse`) halve the fetch: Overpass gives an IP two slots. Current state:
78 tiles, bus graph 1.08M nodes / 2.03M directed edges, 1433 patterns,
36 215 hops, **3.64% chorded**, 0 off-shape, 0 oneway violations, 0 vertices
off the graph.

## 9.1 OSM fetch

Overpass over the GTT stop bbox padded 0.02°, split into ~0.1° tiles so no
response is huge. Use `out geom` so ways carry geometry and tags.

Ways: drivable `highway=*` (motorway, trunk, primary, secondary, tertiary,
unclassified, residential, living_street and their `_link`), `highway=busway`,
`railway=tram`. Keep tags: `oneway`, `oneway:bus`, `busway`, `junction`,
`access`, `motor_vehicle`, `bus`, `psv`.

Descriptive User-Agent. Configurable endpoint list with fallback. Fetch once
per index build, cache the raw result. **Fair use: never re-fetch without a
version bump or 30-day age.** On failure: retry with backoff, then fall back to
`shapes.txt` geometry with every line marked **approximate**; retry next launch.

## 9.2 Graph

Two graphs: bus/road and tram-track.

**Directed edges.** `oneway=yes` (or `junction=roundabout`) contributes edges
only in its tagged direction; `oneway=-1` reverses; `oneway:bus=no` or
`busway=opposite_lane|opposite_track` also allows the reverse for buses;
everything else is bidirectional.

**Exclusions**: no `footway`, `pedestrian`, `path`, `cycleway`, `track`.
Exclude `service` *except* within 100 m of a pattern's own first or last stop
(terminus turnarounds), at a higher cost. Exclude ways closed to motor vehicles
unless `bus`, `psv` or a bus designation allows them.

**Node identity**: dedupe by **exact stored coordinate**. Overpass repeats the
literal shared coordinate at a real junction — no tolerance merge, ever.

Every edge keeps `wayId`, the way's own direction, and a oneway flag. Grid index
for nearest-edge queries.

## 9.3 Snapping patterns

For each GTT **bus and tram** pattern (not regional, not metro, not funicular):

1. Snap each stop to an **edge, not a node**. Consider edges within 40 m allowed
   in the pattern's direction of travel. Score = distance + heading penalty
   against the bearing to the next stop (previous stop for the last one). This
   puts the stop on the correct carriageway. Split the edge with a virtual node.
2. Route each hop (stop i -> i+1) with A*/Dijkstra on the directed graph.
   `cost = length * corridorFactor`, `corridorFactor = 1 + max(0, d - 25) / 25`
   where `d` is the edge midpoint's distance from the pattern's GTFS shape (the
   **modal** shape id of its trips). No shape -> factor 1. Forbid immediate
   U-turns on the same way except at termini.
3. Cap each hop at `max(2500, straightLine * 1.8)` metres.
4. Validate: within the cap, and at most **60 m** off the GTFS shape at any
   vertex when a shape exists. A failed hop becomes a straight chord flagged
   approximate **for that hop only**, never the whole pattern.
5. Cache by `(fromEdgePoint, toEdgePoint, mode)` — many patterns share hops.

Store per pattern: vertex list (Int32 microdegrees), **the vertex index at which
each stop sits**, per-vertex `wayId` (Int64) + direction bit, per-hop approximate
flags, per-stop snapped coordinate. Saved to `lines.bin`, versioned, keyed to
`feed_version`. Tram uses the tram graph. Metro and funicular use their GTFS
shape (or the stop chain) as-is.

## 9.4 Merged ambient network

Per mode, from the snapped patterns:

- For every **directed way segment** used by any pattern, record the set of
  route ids and the set of travel directions.
- **Merge = identical OSM way identity, same mode.** Never proximity. Both
  directions on one two-way way collapse into one feature. Divided roads have
  one oneway way per carriageway, so each direction lands on its own lane
  automatically — **no offsetting there, ever**.
- Chain consecutive segments sharing `(mode, routeSet, directionSet)` into one
  LineString; break where the set changes.
- Feature props: numeric top-level `id`, `mode`, `routes` (comma string), `n`
  (distinct routes), `tier`, `arrow` (0/1), `approx` (0/1).
- `width = base(zoom) * min(1 + 0.4 * (n - 1), 3)` — **cap 3x**. A merged
  feature uses the mode base colour; a single-route feature uses that route's
  own colour (its `route_color` if legible, else a deterministic shade in the
  mode family).
- Tiers by zoom: tier 0 (tram, metro, funicular) always; tier 1 (bus with peak
  headway <= 10 min) from z12; tier 2 (other bus) from z14. A feature's tier is
  the **lowest** among its routes.
- Approximate hops (chords) are excluded from the ambient network.

## 9.5 Bus + tram on one street

Tram tracks are separate OSM ways, so identity cannot merge them. One narrow
documented exception: where a tram segment and a bus segment are **within 12 m
and within 15° of parallel**, draw two parallel strokes offset
`±(half stroke width)` via `line-offset`, one per mode colour. Bus<->tram only.

## 9.6 Arrows

`arrow = 1` **iff the feature's directionSet has exactly one direction**. Purely
from data — covers one-way streets, each carriageway of a divided road, and
two-way streets a route only uses one way. Feature geometry orientation equals
travel direction, so a `symbol-placement: line` chevron layer points correctly.

## 9.7 Stop connectors

The stop dot stays at the stop's true coordinate; a dashed connector joins it to
the pattern's snapped point on the road. Skip connectors under 3 m. Draw only
for currently visible stops. Dedupe when two patterns snap within 1 m.

## 9.8 Tapping a segment

`queryRenderedFeatures` on a 44 px padded box. One route -> its line sheet.
Several -> a picker sheet listing route badges; while open, all candidates draw
thicker; tapping one opens its line sheet.

## 9.9 Focus mode

Selecting a route, journey or vehicle **rebuilds the sources so unrelated lines
and stops are absent, not dimmed**.

- Focused route: both directions at normal width, its stops as small dots,
  termini larger.
- Focused journey: per ride leg, the ridden segment **thick (sliced by the
  stored stop vertex indices)**, the rest of that pattern thin and complete as
  context, both in the leg's mode colour. Only stops on the journey's legs
  remain. Board/alight stops get big circles, intermediate ones small. Stop
  colour matches the leg's mode.

## 9.10 Walking lines

Dotted, round caps, white casing, ~5 px, coloured by a 3-tier distance scale
(<=150 m, <=400 m, >400 m). Tier colours must differ from every mode colour and
hold >= 3:1 contrast on both light and dark basemaps. Geometry: after a journey
is selected, request the walking path from a small on-demand Overpass query
(leg bbox + 150 m, foot-walkable ways, cached) and snap to it. Fall back to a
straight dotted line marked "≈". Displayed walk distance is prefixed "≈" until
the real path is known.

## 9.11 Travelled vs ahead

Split each active leg's geometry at the rider's progress into two features
(`travelled = 1/0`). **No gradients.** Progress is monotone: search only forward
from the last progress index, within a 60 m cutoff; beyond it keep the last
progress and show "position uncertain". Legs before the current one are fully
travelled. Travelled = mode colour desaturated at ~40% opacity; ahead = full
colour. Walk legs split the same way.

## 9.12 Validation — must pass before GATE 2

`tool/lines_report.dart` prints, per line and overall: patterns fully snapped,
hops chorded, hops off-shape, edges violating a oneway, vertices more than 8 m
from any graph edge (chords excluded).

Unit tests on synthetic graphs (`test/lines_unit_test.dart`), all green: a
two-way junction; a oneway pair where directions 0 and 1 take different edges;
a loop route where a shared stop appears twice (index slicing takes the right
pass); a same-way merge of three routes giving `n = 3` with width capped at 3x
(`lib/geo/line_merge.dart`, shared by `tool/gate1_samples.dart` and, from 9.4,
by the app layer).

Device check: a scripted tour of fixed viewports — a corso with dual
carriageways, a shared bus/tram street, the Peschiera/Racconigi corridor, a loop
route's turnaround, the city centre at z12/z14/z16 — inspected for gaps,
off-road segments, doubled lines, missing lines, wrong colours, wrong lane.
