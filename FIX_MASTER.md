# FIX MASTER PLAN (supersedes FIXPLAN*, FIX_PLAN*, FIX_PHASES, FIX_AGENT_COMMANDS)

Old fix files stay until user OKs deletion (Phase 7 lists them).
Run one agent per phase: "do phase N of FIX_MASTER.md, phone is plugged in".
Each agent loads skill `piedemove-fixes` first, then only the skill its phase names.

## Ground rules (every phase)

1. **No arbitrary code.** No hardcoded line ids, stop ids, coordinates, per-line
   patches, magic offsets. Every fix is a general rule over feed/OSM data.
   A fix that only works for line 33 is a failed fix.
2. **Data-driven, refreshable.** Geometry comes from GTFS (GTT) + OSM (Turin roads)
   through `tool/build_index.dart` and `tool/build_lines.dart`. Re-running them on
   new data must reproduce a valid result; the gap test (Phase 1) re-validates it.
   Never hand-edit generated assets.
3. **Clean base logic.** One owner per concern (focus controller, location
   controller, journey-geometry builder). UI reads state, never mutates others' state.
   Named constants in one place: `lib/ui/map/map_style.dart` (widths, opacities,
   dot sizes, cutoffs). No literals in layer code.
4. **On device.** Routing, snapping, progress projection, gap check all run offline.
   Online allowed only for: map tiles, Photon, GTFS-RT, Overpass (walk snapping,
   cached, with straight-dotted "≈" fallback). Every online piece degrades, never blanks.
5. **Isolation.** Each map layer in its own try/catch; failure = status chip.
6. Per phase: plan -> small diffs -> `flutter analyze` clean -> `flutter test`
   green -> build, `adb devices`, install -> ONE downscaled (~720px) screenshot
   per check, looked at -> `graphify update .` -> commit with tag. Report
   verified-live vs replay/code-only, plainly.
7. Never `git add -A`. Stage only files the phase touched. No `.orig/.rej/.png/.patch` in commits.

## Phase 0: repair the tree (BLOCKER, do first)

Found: 17 tracked files are **empty in the working tree** (git shows only deletions):
PLAN.md, piedemove-data/SKILL.md, piedemove-release/SKILL.md, index_io, index_merge,
index_source, transit_index, ambient, line_build, journey, raptor, about_page,
line_sheet, trip_sheet, scheduled_only, test/index_merge_test, tool/build_index,
tool/build_lines. App cannot build. Earlier fix agents did this (likely failed
patch/`.rej` runs).
- `git diff --numstat` shows 0 added lines for them -> nothing to lose: `git checkout HEAD -- <those files>`.
- `assets/ambient.json.gz`, `assets/lines.bin.gz` are modified binaries: compare with HEAD, rebuild via tools if in doubt.
- Delete stray `*.orig`, `*.rej`, `*.patch`, `*.png` in repo root/lib (move pngs to `docs/shots/` or ignore).
- Gate: analyze clean, tests green, golden case (Politecnico -> Cristalliera) passes, app installs.
- Commit `chore: restore truncated files, clean strays`.

## Phase 1: interrupted lines (Fix 1)  skill: piedemove-lines
- `tool/gap_detector.dart` + `test/gap_detector_test.dart`: walk emitted map geometry per pattern
  (same code path as map source, not raw paths). Flag: features not sharing endpoint >1 m,
  vertex gap >150 m, missing hop. Print pattern, hop, cause. Test runs on the real asset.
- Fix by cause found, in order: unsnapped hops drawn as thin dotted segment (approximate,
  marked); chain joints share exact vertex; round cap/join on all line layers;
  GeoJSON `tolerance` ~0, `buffer` up; filters never split one route; numeric top-level
  `id`, primitive-only properties.
- Gate: zero gaps; visual scan city centre z12/14/16.

## Phase 2: focus survives everything (Fix 3)  skill: piedemove-ui, piedemove-lines
- `FocusController` (Riverpod): line | vehicle | trip. Only `close()` (X) and `cancella()` clear it.
- Cancella pill near top of map whenever anything focused; live trip -> confirm "Terminare il viaggio?".
- Sheet: peek/half/expanded snaps, peek is resting, sheet takes only its own height.
- Own source+layers for focus. Realtime updates vehicles only. Camera-idle/zoom/lifecycle never
  rebuild it; ambient tiering skipped while focused. Fit camera once on select.
- Gate: verify steps 1-3 of the checklist.

## Phase 3: ridden segment + stop dots (Fix 2 + dot sizes)  skill: piedemove-ui
- `map_style.dart`: `ridden` width >= 2x `context`, zoom-interpolated, with casing; ridden above context above ambient.
- `kind` property drives style. Slice ridden by stored stop positions along path, never nearest-point.
- **Dot sizes:** origin/destination and first/last stop of a ride: ~14 dp; intermediate stops ~8 dp
  (constants `endDot`, `midDot`, white ring). Ends always above mids.
- Gate: z13/15/17 on bus, tram, metro legs.

## Phase 4: position dot (Fix 4)  skill: piedemove-phone-test
- `LocationController`: permission + service check at first launch, chip "Attiva posizione"
  -> system settings on denial. Last-known first, then ~1 Hz stream, foreground only,
  pause/resume on lifecycle. Optional heading wedge if compass exists.
- Own GeoJSON source: blue dot, white ring, accuracy circle. Re-added on every style load, top of stack, own try/catch.
- My-position button recentres. Works with and without trip.
- Gate: steps 5 (launch, theme toggle reload, recentre).

## Phase 5: walk paths (Fix 5)  skill: piedemove-routing, piedemove-lines
- Find why missing first (access/egress not emitted? kind filter? focus filter? z-order?). Fix the cause.
- One walk feature per walk leg (access, transfer, egress). Snap via cached on-demand Overpass
  (leg bbox +150 m, foot-walkable ways, reuse `walk_path.dart`/`road_graph.dart`); on failure
  straight dotted + "≈" distance.
- Dotted, round caps, white casing ~5 px, 3-tier distance colours. Above ride context, below stops
  and position dot. Fully visible in focus. Destination pin, origin = position dot or start marker
  (uses Phase 3 end-dot size).
- Gate: step 6.

## Phase 6: live progress on every leg (Fix 6)  skill: piedemove-phone-test, piedemove-routing
- Single progress engine over the Phase 4 stream, same for walk and ride: forward-only projection on
  current leg geometry, 60 m cutoff (beyond: keep progress, "posizione incerta").
- Split active leg into `travelled` / `ahead`; earlier legs fully travelled; later untouched.
  Travelled opacity = one constant (~0.15). Dot sits on the boundary.
- Advance at 25 m of walk end / 60 m of alight stop. Manual buttons stay.
- Strip text: "Cammina ancora N m fino a <stop>" / "fino alla destinazione". Start trip works when leg 1 is walk.
- Unit tests: projection monotonic, cutoff, advance, split. Replay test with recorded track.
- Gate: step 7 (real walk if possible, else mock-location replay; say which).

## Phase 5b: real pedestrian routing (user: walks must follow roads/crossings like Google Maps)  skill: piedemove-routing
Design (final, user-decided): ONE versioned walking graph, layered sources, NO Overpass at runtime.
- `tool/build_walk.dart` (reproducible, general OSM-tag rules, Overpass/PBF only at build time, cached in build/):
  footway/path/pedestrian/steps/living_street/walkable roads, passages, crossings as explicit
  nodes/edges (zebra/signals/uncontrolled), exclusions foot=no/private/motorway; penalised mid-block
  fallback on minor streets only. Header: format version, OSM date, bbox, sha256. Compact payload.
- Shipped copy in assets/. Loader order: downloaded on disk -> shipped -> straight dotted "≈".
- Updater `lib/geo/walk_graph_update.dart`: manifest.json (version,date,sha256,size,format,bbox,url),
  URL in one constant, ETag, <=1/day, foreground, verify hash+format, atomic swap, silent on failure.
- Router (A*), edge-projection snapping, penalties as named constants, docs/walk_routing.md.
  Output per leg: polyline, true metres, time, maneuver list (turns, crossings, steps). Reroute-from-position fn.
- Displayed AND scored walking metres = routed distances; golden case must pass.
- Publish/push nothing; no workflow (that is 5c).
Split to save tokens, medium effort, one agent each, token ceiling per agent:
- **5b-A (data+loader, no phone):** build tool, format+header, shipped asset, loader layering, updater + fake-HTTP tests, fixtures.
- **5b-B (router+integration):** router, penalties, maneuvers, reroute, replace phase-5 walk drawing/distances/scoring, golden, then phone checks (one screenshot tour).

### STATE (2026-09-24, before context clear)
Done+tagged: 0, 1, 1b, 1c, 2, 2b, 3, 4, 5. Assets ambient/connectors/lines.bin.gz are regenerated but UNCOMMITTED (needed for on-device match; commit them in a small chore).
5b: two agents were stopped by the user for token cost. Working tree holds UNREVIEWED, UNCOMMITTED partial work
(lib/geo/walk_{build,costs,graph,graph_update,providers,router}.dart, lib/routing/walk_legs.dart, tool/build_walk.dart,
assets/walk_graph.pmwg.gz, docs/walk_routing.md, test/walk_*.dart + fixtures, edits in journey/raptor/providers/line_features/
map_view/about_page/trip_*/live_trip, walk_path.dart deleted, pubspec). The router was mid-rewrite (multi-candidate seeds/goals in route/_search).
Next session: `git status`, run analyze+tests to see if it builds, then review vs this section and either finish (5b-A then 5b-B) or revert.
Then: 5c, 6 (split: 6a pure progress engine + unit tests, 6b UI/strip/phone), 7 (split: 7a styles, 7b contrast+phone), 8.

## Phase 5c: keep walk graph fresh (after 5b, needs user OK to publish)
- Scheduled GitHub Actions workflow: runs `tool/build_walk.dart`, hashes, replaces fixed release
  tag `walk-graph-latest` (graph + manifest.json) only if changed; sanity check fails the run on
  big size/connectivity swings; keep-alive step; manual "run now". Optionally also rebuild line assets.
- Publishing is outward-facing: agent prepares the workflow, user approves before first release.

## Phase 7: map styles and contrast (new)  skill: piedemove-ui, piedemove-lines
Problem: basemap contrast is poor; only app-wide light/dark exists.
- Audit first: current basemap source/style, how theme switches it, what overlays (lines, walk,
  stops, vehicles, dot) sit on.
- Independent **map style setting**, separate from app theme: Auto (follows app), Light, Dark,
  Colour (coloured, clearly visible roads), High contrast. Stored in settings, applied live
  (style reload must re-add every layer; reuse the phase 4 re-add pattern).
- Basemap: vector tiles from OpenFreeMap (free, no key, prod-usable) styled by our own bundled
  style JSON per variant, not a third-party style we can't tune. Road hierarchy by colour and
  width (motorway/primary/secondary/minor/pedestrian), water/parks/buildings muted so transit
  overlays dominate, labels legible with halos. Attribution (OSM, OpenFreeMap, OpenMapTiles) kept.
- Overlay palettes validated against each style: line colours, walk dotted, stop dots, vehicles,
  position dot must meet a contrast ratio (>= 3:1 vs local basemap) in every style; script/test
  computes it from the style + palette tokens, no eyeballing only.
- Named tokens in `lib/ui/map/map_style.dart` / style assets, no per-line colours. Offline: style
  JSON bundled; tiles online with cache; tile failure = chip, overlays still work.
- Gate: each style at z12/14/16 screenshot, transit lines readable in all, theme x style matrix works.

## Phase 8: final verify + cleanup
- Run all 8 checklist items from the original request, one screenshot each, in at least two map styles.
- Gap test zero, analyze, tests. Update skills touched. Tag.
- List old fix files for user to approve deletion; do not delete unasked.

## Order/deps
0 -> 1 (1b, 1c) -> 2 (2b) -> 3 -> 4 -> 5 (5b) -> 5c -> 6 -> 7 -> 8. Phase 2 owns focus layers that 3 and 5 draw into.
Phase 4 feeds 6. Phase 3 dot constants used by 5.
