# Walking routes (fix phase 5b)

Rides cost nothing, so walking metres are the product's cost. Walking is
computed on a real pedestrian graph, on the phone, with no network.

## Pieces

| What | Where |
|---|---|
| Graph model, binary codec, header | `lib/geo/walk_graph.dart` |
| OSM tags -> graph (build time only) | `lib/geo/walk_build.dart`, CLI `tool/build_walk.dart` |
| Cost model, every tunable number | `lib/geo/walk_costs.dart` |
| Snapping, A*, maneuvers, re-route | `lib/geo/walk_router.dart` |
| Daily silent update | `lib/geo/walk_graph_update.dart` |
| Load order, providers | `lib/geo/walk_providers.dart` |
| Re-pricing planned journeys | `lib/routing/walk_legs.dart` |

## The graph

Built by `dart tool/build_walk.dart` from one Overpass fetch per 0.04 degree
tile of the Turin bbox (cached gzipped under `build/walk_osm/`, used only at
build time). Rules are general tag rules; nothing is keyed to an id or a
coordinate. Same input, same bytes.

* **Dedicated ways**: footway, path, pedestrian, track, corridor, steps
  (kind `steps`), shared cycleways only with `foot=yes|designated`. A
  `footway=crossing` way is a crossing edge typed by its tags. Covered
  passages and arcades (`covered=yes|arcade`, `tunnel=building_passage|arcade`,
  `indoor=yes`) carry a flag.
* **Minor streets** (residential, unclassified, living_street, service) are
  walked on the carriageway.
* **Busy roads** (tertiary, secondary, primary, trunk, and their links) get a
  generated sidewalk on each side (6 m from the axis, mitred), so a walker is
  always on one side of them. Which side has a sidewalk (`sidewalk=*`,
  `sidewalk:left|right|both`) is stored per side.
* **Junctions of busy roads.** The arms are sorted by bearing, and a *corner*
  node sits between each pair of neighbouring arms. Both sidewalks of an arm
  end at its two corners, and the two corners are joined by a **crossing
  edge**: typed by the node's tags (`crossing=traffic_signals|zebra|marked|
  uncontrolled|unmarked`, `highway=traffic_signals`) or, untagged, *unmarked*.
  A junction with nothing attached and no tag (a road merely continuing across
  a way boundary) gets no crossing. Minor streets and footways attach to the
  corner on their side, so they cross nothing to walk along the road.
  That untagged unmarked crossing is the "mid-block fallback": heavily
  penalised, it is what keeps the graph connected when OSM lacks a crossing,
  and it exists only at junctions of ways that exist, never across a
  motorway or rail (those are not walkable, so no crossing is generated).
* **Excluded**: `foot=no|private`, `access=no|private` (unless foot allows),
  construction/proposed, motorway (unless `foot=yes`), road tunnels with no
  pedestrian provision, cycleways for bikes only, rail. Components of fewer
  than 20 edges are dropped (an island cannot be reached).
* **Pedestrian areas** are walked along their outline only (interior not
  routed): a known gap.

Degree-2 nodes with identical attributes are contracted; geometry is
simplified to 0.7 m.

## File format (version 1)

Header 68 bytes: magic `PMWG`, u16 format, i64 OSM time, bbox (1e-5 deg),
payload length, sha256 of the payload. Payload: name table, nodes (sorted,
delta varints, 1e-5 deg), edges (a delta, b delta, flags byte, name, geometry
deltas). Shipped and downloaded as gzip. Same parser for every source.
`manifest.json` (written next to it): format, version, date, bbox, size,
sha256 of the gz file, payload sha256, url.

## Cost model

Cost = true length x factor + fixed metres (crossings). The displayed
distance is always the true length; cost only picks the path.
All numbers are in `walk_costs.dart`.

| Edge | Cost |
|---|---|
| dedicated path / sidewalk / pedestrian zone / rough track | 1.0 / 1.0 / 0.95 / 1.3 |
| minor street / living street / service lane | 1.0 / 0.95 / 1.3 |
| sidewalk of a busy road | 1.0-1.1 if OSM says a sidewalk is there, 1.15-1.4 if unknown, 1.6-2.5 if none, by class (tertiary < secondary < primary): major-road proximity is priced here |
| steps | x3 |
| covered | x0.9 |
| crossing | + 20 signals, + 25 zebra, + 30 uncontrolled, + 120 unmarked |

Signals are cheapest (safest); unmarked is heavily penalised. Tunnels and
underpasses are ordinary edges (no penalty).

## Router

A* on nodes, straight-line heuristic scaled by the smallest factor
(admissible). Origin, destination and stops are **projected onto the nearest
edge** (grid of ~60 m cells over every edge segment), so the path starts
mid-edge, not at a node; the off-network stretch (up to 150 m) is drawn and
counted in the metres. Farther than that from any edge means "outside
coverage": no route, the leg stays straight dotted "≈". A same-edge walk is
one candidate; a detour can still win when both points sit at edge ends.

Output per leg (`WalkRoute`): polyline `[lon, lat]` on the real edges, true
metres, seconds at `walkSpeedMetresPerSecond` (1.2 m/s), and an ordered
maneuver list: start; turn (slight/left/right/sharp, straight when the street
name changes) with street name; cross X at signals/zebra/...; steps; arrive.
Each has a polyline index and the metres until the next one. Turn angles use
12 m windows so junction corners do not produce noise.

`WalkRouter.reroute(lat, lon, route)` routes from an arbitrary current
position to where the route was heading (phase 6 off-route handling).

## Planning vs routing

RAPTOR needs walking distances between every pair of nearby stops (a footpath
table of ~10^5 pairs) and prices them as straight-line metres. Routing all of
them on a phone is too heavy, and the table must exist before the search. So:

1. RAPTOR proposes candidates with the estimate; it runs with the walk cap
   widened by the detour factor 1.35, so a journey whose *real* walk is longer
   than it looked is not lost.
2. `routeWalks` re-prices the (few) journeys returned: every walk leg gets the
   routed metres and time, a journey whose real walk misses its connection is
   dropped, and the real cap is applied.
3. The lists are sorted afterwards, so the displayed **and** the scored metres
   (`score = walkMetres + w * minutes`) are the routed ones.

Ceiling: the Pareto front was built on estimates, so a candidate that is
dominated only under the estimate but better in reality can be missing. Upgrade
path: route the footpath table lazily per stop pair, or widen the front.
Where the graph does not cover a leg (or no graph loaded), the estimate is
multiplied by 1.35, the leg stays unrouted and is shown with "≈".

## Sources and updates

Load order: downloaded file (`<support>/walk/walk_graph.pmwg.gz`, valid and
format-compatible) -> shipped asset `assets/walk_graph.pmwg.gz` -> none.
`WalkGraphUpdater` reads `manifest.json` from `walkManifestUrl` (one named
constant), at most once a day, foreground only, `If-None-Match`; downloads to
`.tmp`, verifies size, sha256 and format, then renames. Any failure keeps the
current graph, silently. A newer format is ignored. Nothing waits for it.

## Data

(c) OpenStreetMap contributors, ODbL. Credited on the About page.
