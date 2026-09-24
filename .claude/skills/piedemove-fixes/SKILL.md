---
name: piedemove-fixes
description: Rules and phase map for the current fix round (line gaps, focus, ridden segment, position dot, walk paths, live walk progress). Load first when the user says "do phase N of the fix" or FIX_MASTER.md is mentioned.
---

# Fix round

Source of truth: `FIX_MASTER.md` (repo root). Read it once, do only the named phase.
Older FIX*.md files are superseded; ignore them.

## Non-negotiables
- No arbitrary code: nothing keyed to a line id, stop id or coordinate. General rules over GTFS/OSM data only.
- Generated assets come from `tool/build_index.dart` / `tool/build_lines.dart`; never hand-edit. Must re-run cleanly when GTT or Turin roads change.
- All logic on device. Online only: tiles, Photon, GTFS-RT, Overpass (cached, with fallback).
- One owner per concern: FocusController, LocationController, journey-geometry builder, progress engine.
- Style numbers live in `lib/ui/map/map_style.dart` (widths, opacities, dot sizes: end ~14 dp / mid ~8 dp, travelled opacity ~0.15, cutoffs 60 m / 25 m).
- Each layer in its own try/catch; failure = status chip.
- Stage only touched files. No `.orig/.rej/.png/.patch` commits.

## Known trap
Earlier fix agents left 17 tracked files empty (PLAN.md, raptor, ambient, trip_sheet, ...). Before any work run
`git diff --numstat | awk '$1==0 && $2>0'`; if hits exist, do Phase 0 first.

## Phase loop
plan -> small diffs -> analyze -> test -> build -> `adb devices` -> install -> one 720px screenshot per check, looked at
-> `graphify update .` -> update the touched skill -> commit + tag. Report verified-live vs replay/code-only.

Phases: 0 repair tree, 1 gaps, 2 focus, 3 ridden+dot sizes, 4 position dot, 5 walk paths, 6 live walk progress, 7 final verify.
