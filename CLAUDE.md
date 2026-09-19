# PiedeMove

Android (Flutter) public-transport planner for Turin, for free-pass holders.
Rides cost nothing, so **walking metres are the cost**. Shows *every* line that
can make a hop, generates footpath transfers between nearby stops, and trades
waiting/transfers for less walking. Bus, tram, metro, funicular. No fares, no
cars/bikes, no walking-only trips. Fully on-device: no backend, no Google data.

Golden case: Politecnico -> Via Cristalliera must find TRAPANI -> PESCHIERA
(126 m hop) + line 2 to BARDONECCHIA, not Google's "33/42 then walk".

## Build / test

    flutter analyze                 # must be clean
    flutter test                    # must be green
    flutter build apk --release && flutter install -d <serial>
    adb devices                     # serial changes between sessions - always check
    dart tool/build_index.dart      # GTFS ingest -> index.bin
    dart tool/lines_report.dart     # line-snapping validation (phase 6 gate)
    dart tool/discover_hops.dart    # find footpath-transfer wins

## Layout

    lib/data      feeds, zip streaming, GTFS parse, index build/io, clustering
    lib/routing   footpaths, raptor, journey model, scoring, departures
    lib/realtime  GTFS-RT decode, store, polling, alerts
    lib/geo       osm fetch, road graph, pattern snapping, line network
    lib/location  device location, live trip controller
    lib/places    photon client, local search index
    lib/ui        theme/ map/ sheets/ widgets/
    tool/         build_index, discover_hops, lines_report

State: Riverpod. One `entityNav` controller owns the detail-page stack.

## Rules

- **Plan before code.** Per phase: plan -> implement -> analyze/tests ->
  device screenshot check -> update the touched skill -> commit + tag.
- **Never leave the app broken.** Every phase ends analyze-clean, tests green,
  installed on the phone, screenshots *looked at* (not assumed).
- **Isolate failures.** Routing must work with lines, live feeds, geocoding and
  Overpass all down. Every map layer added in its own try/catch; a failure shows
  a status chip, never blanks the map or planner.
- **No credentials** in prompts, notes, skills or commits. Nothing needs sudo.
- **Copy no code** from ../piemove-maps (read-only reference for data facts only).
  Its line-drawing / road-snapping / merge code is why this repo exists.
- Approximate data is always marked, never silently guessed.
- Stop only at the gates (see PLAN.md). Locked decisions are not re-opened.

## Token discipline

- Detail lives in skills, loaded on demand: `piedemove-data`, `-routing`,
  `-lines`, `-ui`, `-phone-test`, `-release`. Update only the skill a phase touched.
- Query the graphify graph instead of opening files to locate things.
- One task per session; clear between tasks. Resume, don't re-explain.
- Effort low/medium by default; high only for routing (§7) and lines (§9).
- Edit with diffs, never rewrite a file for a small change.
- No polling loops. One blocking command with a timeout, then move on.
- Screenshots: downscale to ~720 px, one per check, after the build finishes.
- Exploration and data inspection go to a sub-agent that returns a summary.
- Per-task token ceiling: pass it -> stop, report done/left/cost, wait.
- Never paste the spec into a prompt. Read PLAN.md once per task.
