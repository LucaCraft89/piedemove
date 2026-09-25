---
name: piedemove-lines
description: Road/tram graph, snapping patterns to streets, the merged ambient line network, arrows, connectors, focus mode, walking lines, travelled-vs-ahead, and the line validation report. Load for anything in lib/geo, any map line geometry, or phase 6. Read the Lessons section first - each rule exists because a previous attempt failed.
---

# Lines (§9) — rewritten from scratch

Its own module (`lib/geo/`) with its own cache file, so a failure here never
affects routing. Copy nothing from `../piemove-maps`. High-effort work.

## Lessons - why each rule exists

1. Slice a route by **vertex index recorded at build time** (stop offsets),
   never by nearest-vertex search: loops and shared stops pick the wrong pass.
2. **Directed graph**, each pattern matched in its own direction: reusing one
   direction reversed draws the wrong carriageway on divided roads.
3. Pedestrian and service ways (`parking_aisle`, `driveway`) are out of the bus
   graph: they cause off-road jogs and shortcuts.
4. "Same road" is decided by **graph segment identity** (mode + node pair),
   never by distance, grid cells or shifts: proximity merged unrelated lines.
5. GeoJSON features need a **top-level numeric `id`** or Android renders none.
6. Feature properties are **primitives / comma strings**; arrays do not query
   back reliably.
7. Each map layer in its own try/catch, plus a visible status chip.
8. Overpass 504s on a regex over `highway` values and answers ~2 s for the
   bare `way["highway"]` key; `overpass.osm.ch` answers 200 with an empty list.
   A tile under 2 KB is a miss. A tile that still 504s is fetched as four
   quadrants and stitched. Regex on `railway` is fine over a small bbox.
9. `queryRenderedFeaturesInRect` returns the id as a String on Android, a num
   elsewhere: parse either.
10. **Per-hop routing was the root failure** (phase 1c). Routing stop to stop
    turns every unroutable hop into a straight chord (6.7% of drawn length, runs
    of 34 km), and stops that split OSM segments make every pattern cut the
    network differently, so merging fragments and cleaner passes multiply. The
    GTFS **shape** is the evidence of the real path: match the whole pattern to
    the graph with a HMM, keep whole segments, place stops afterwards.
11. GTT publishes real **contraflow bus lanes untagged**: a shape running against
    a one-way is not noise. Keep the contra edge at a penalty (`isContraflow`);
    without it 770 shape-following hops became dotted jumps.
12. Tram track must be in the **bus graph** too (penalty): a route typed bus can
    run on a rack line. Metro/funicular have their shape; a shape-less one is
    routed stop to stop on the rail graph.
13. A wide-radius retry must accept only edges the sample projects **beside**
    (0 < t < 1): a road that merely ends near the shape must not claim samples
    beyond its end, or the dotted stretch starts 50 m late as a long chord.
    Trim run-end samples clamped at an edge end for the same reason.
14. Spur removal on the finished path must compare **direction as well as
    position**: two consecutive sub-metre edges are "reversed" under a loose
    position test and get deleted, cutting the drawn line (gap detector caught
    it). Node-id reverse, or position within 0.5 m **and** bearing > 150 deg.
15. Dotted stretches must be keyed by **all their points**: endpoints + count
    collided across different shapes and dropped geometry.
17. MapLibre accepts `["zoom"]` only as the input of **one top-level**
    `step`/`interpolate`. Nested (`["*", interpolate(zoom), n]`, a zoom step
    inside `case`) it is rejected at runtime, logged only as `E Mbgl ...
    Error setting property`, and the property silently takes its default:
    every ambient line drew 1 px, opaque, all tiers at all zooms, until
    beta 3. Put the arithmetic inside each stop (`ambientWidth(extra:)`,
    `tierOpacity(factor:)`); `test/map_expressions_test.dart` pins the rule.
16. No smoothing, no bus/tram shift: OSM geometry equals the basemap. Where bus
    and tram share a street, tram is drawn first and wider, bus over it.

## Build

    dart tool/build_lines.dart [--force-osm] [--reverse] [--no-assets]
    dart tool/lines_report.dart [--spurs|--dev|--fail]   # quality report
    dart tool/gap_detector.dart / knot_detector.dart     # both must print 0

One command regenerates everything shipped: `build/lines.bin`,
`assets/lines.bin.gz`, `assets/ambient.json.gz`, `assets/connectors.json.gz`.
GTFS shapes are read first (they decide which tiles/ways matter); OSM tiles are
cached gzipped in `build/osm/`, plus `rail_v1_*` for metro/funicular. About 30 s
on cached tiles; `build/gaps.txt` lists every dotted stretch with its cause.
Two processes (the second with `--reverse`) halve the tile fetch.

State (feed 20260919): bus graph 449k nodes / 907k directed edges (corridor
around the shapes), 1429 patterns, 36 163 hops, **0.63% hops dotted (0.17% of
length, longest 1.4 km)**, detour p95 1.013, stop offsets monotone, 0 gaps,
0 knots. Remaining dotted stretches are data: no OSM road under the shape
(private/pedestrian areas, missing ways) or a shape 70 m+ off the road.

## 9.1 OSM fetch

Overpass tiles (0.1 deg, 0.02 overlap) for the stops **and shapes** of GTT bus
and tram patterns; `out geom` so ways carry geometry and tags. One extra call
for metro/funicular tracks. Cached; fair use: never re-fetch before 30 days or a
cache-version bump. On failure the tile is skipped: the patterns fall back to
their shape, dotted.

## 9.2 Graph

`lib/geo/road_graph.dart`. Node = **exact stored coordinate**. One directed edge
per OSM way segment (point to point), keeping `wayId`, reverse bit, service,
rail and contraflow flags. Oneway semantics: `oneway=yes|-1`, roundabout,
`oneway:bus=no`, `busway=opposite_*`. Bus graph: drivable highways incl.
`busway`, service (not aisles/driveways), tram track at a penalty; no footway,
path, cycleway, track; ways closed to motor vehicles unless bus/psv allowed.

## 9.3 Matching a pattern

`lib/geo/map_match.dart` (`PatternSnapper.snap`), model and stop placement in
`lib/geo/pattern_snap.dart`.

1. Resample the shape every 15 m; heading over +-15 m.
2. Candidates: edges within 35 m (70 m beside-only if none), <= 8 per sample.
   Cost = 0.5 (d / 10 m)^2 + 3 (heading delta / 90)^2 + penalties (service 1,
   tram-in-bus-graph 2, contraflow 3).
3. Transition = |graph route - shape arc| / 3 m, U-turn +6, bounded local
   Dijkstra (2 gc + 50 m). Viterbi; no finite transition or no candidate ends a
   run.
4. Runs -> edge sequences; first/last edge dropped if the shape barely touches
   it; spurs < 60 m removed on the whole path.
5. Gap between runs: shortest path hugging the shape (corridor factor, <= 1.4 x
   gap + 120 m, all edges within 40 m of the shape), else the shape's own points
   as a dotted stretch.
6. Stops: monotone Viterbi over path positions within reach (never backwards),
   each gets a vertex; `stopVertex`, `hopApprox` (hop touches a dotted stretch).
7. No shape: stops snap to an edge heading their way and are joined by shortest
   paths; failures are dotted straight pieces.

Stored per pattern: Int32 microdegree vertices, `vertexWay` + dir bit, stop
vertex, snapped stop coordinate, hop flags. `vertexEdge` (graph edge id, -1
dotted, -2 shape) is desktop only, used to merge the ambient network.

## 9.4 Merged ambient network

`lib/geo/line_merge.dart`, `lib/geo/ambient.dart`. Per physical segment (mode,
node pair): route set and direction set. Chain segments sharing (mode, route
set, direction set) at nodes with exactly one way in and out (undirected walk
for two-direction sets), break at forks/ends/set changes. Properties: numeric
`id`, `mode`, `routes`, `n`, `tier`, `arrow`, `shade`, `approx`. Dotted
stretches ship as `approx = 1` features (the shape polyline). Metro/funicular
with a shape: the longest pattern per route plus any pattern serving a stop not
yet covered. Width = `base(zoom) * min(1 + 0.4 (n - 1), 3)` x mode factor
(`railWidthFactor` for tram/metro/funicular); tram is listed first, bus over it.
Tiers as before (0 tram/metro/funicular, 1 bus <= 10 min peak headway, 2 other).

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

`lib/geo/walk_path.dart`: one Overpass call over the leg bbox, a
`GraphMode.foot` graph over the answer, one Dijkstra, cached for the session;
any failure leaves the straight dotted line. The displayed walk distance always
carries the "≈" marker (`metresLabel(..., approximate: true)`).

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

## 9.12 Validation

`dart tool/lines_report.dart` (dotted share, longest dotted run, detour ratio,
path/shape deviation, monotone stops, invented spurs), `gap_detector` (every hop
drawn, joints shared), `knot_detector` (folds > 150 deg, legs <= 15 m). Tests:
`test/lines_unit_test.dart` (synthetic graphs), `test/gap_detector_test.dart`,
`test/knot_detector_test.dart` run on the shipped assets.

Device check: `adb shell cmd location providers` mock location + a dev camera
hook, or a pinch sent with `sendevent` right after launch (it only works before
any other touch). Look at: a corso with dual carriageways, a shared bus/tram
street, the Peschiera/Castelfidardo corridor, a roundabout, the centre at
z14/z16, a suburban stretch, a metro line.

## Walk paths (fix phase 5)

Root cause of missing walks: `walkFeatures` never received the origin (the access leg has `fromStop == -1`, so it was skipped) and the destination came from `selectedPlaceProvider` (the search pin, null when the destination was picked in the planner), so egress was skipped too. Both ends now come from the trip query via `walkLegEnds(ix, leg, origin:, destination:)` (`line_features.dart`), shared by drawing and by `_fetchWalkPaths`. Layers `pm-walk-casing` (white, dotted, same absolute spacing via `walkDash`) + `pm-walk-lines` (3-tier colour), constants `walk*` in `map_style.dart`, above focus lines, below focus stop dots and the position dot. `walkPath` caches solved paths on disk (`<support>/walk/`) and in memory; failures are never cached (retry when back online) and set the chip "Percorsi a piedi approssimati"; legs stay straight dotted with the "≈" figure. Tests: `test/walk_legs_test.dart`.
Verified on phone 2026-09-24: transfer (snapped, bent path), egress, offline fallback (wifi+data off: straight dotted + chip). Access-from-position not seen separately (position was on the first stop).

## Following GTT without an app update (2026-09)

- `lines.bin` format 2 stores `patternSignature(ix, p)` = short name | route
  type | stop ids in order, per pattern. Pattern **numbers** change with every
  GTT export; never key geometry by them across feeds.
- `rebaseLines(source, ix)` (`lib/geo/lines_rebase.dart`) re-keys geometry onto
  the phone's index; a pattern with no match (new/rerouted line, regional,
  no file) becomes `stopChordPattern`: stops joined straight, every hop
  `hopApprox`, `synthetic = true`, drawn with `approx = 1` (dotted). Format 1
  is trusted by number for its own feed only.
- `.github/workflows/lines.yml` (daily, dispatch, `workflow_call`): GTT index ->
  feed changed vs `lines-latest/manifest.json`? -> Geofabrik extract cut to
  `tool/lines_bbox.dart` -> osmium OPL with node locations -> `build_lines.dart
  --opl` (same graph code as Overpass tiles, via `oplWaysToOverpassGeom`) ->
  gates `lines_report --fail` + `gap_detector` -> `tool/lines_manifest.dart` ->
  publish lines.bin.gz, ambient.json.gz, connectors.json.gz, manifest last.
- App: `LinesUpdater` (`lib/geo/lines_update.dart`), <= 1/day in the
  foreground from `ambientLinesProvider`: downloads a set built from another
  feed into `<support>/lines/set-*`, checks size + sha256 + decodes, then
  switches `current.json` atomically; old sets pruned. Providers read the
  current set first, then the assets; the map swaps the ambient source in
  place (`_ambientDrawn`).
- ci.yml: a `[release]` (or `[lines]`) push runs the lines workflow; the release
  job bundles `lines-latest` into the APK when its format matches.
- Schedules only run from the default branch: the daily rebuild starts once
  `lines.yml` is on `main`.
