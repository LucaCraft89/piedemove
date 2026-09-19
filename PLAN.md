# PiedeMove plan

State that must survive a session lives here and in `.claude/skills/`.
Read this once per task. Do not paste it into prompts.

## Status

| Phase | What | State |
|---|---|---|
| 0 | Token/workflow setup: repo, skills, graphify | **done** |
| 1 | Data + routing core, no UI | todo |
| 2 | Shell, map, stops | todo |
| 3 | Realtime + vehicles + entity sheets | todo |
| — | **GATE 1** design: palette, line style, UI samples | blocked on 3 |
| 4 | Search (Photon, stops, lines, vehicles) | todo |
| 5 | Planning UI + settings | todo |
| 6 | Lines (§9): fetch, graph, snap, validate, ambient, focus, walk | todo |
| — | **GATE 2** data: validation report + 3 sample spots | blocked on 6 |
| 7 | Live trip (needs a real ride) | todo |
| 8 | Metro entrances, favourites, advanced mode, About | todo |
| 9 | Regional buses (scheduled only) | todo |
| 10 | Release: README, licence, APK | todo |
| — | **GATE 3** final acceptance on the phone | blocked on 10 |

Phase 6 internal order: 9.1 fetch -> 9.2 graph -> 9.3 snapping -> 9.12
validation + unit tests -> GATE 2 -> 9.4-9.7 ambient -> 9.8 taps -> 9.9 focus
-> 9.10 walking lines.

Gates: stop and wait for the user. Nowhere else.

## Locked decisions (do not re-ask)

Android only, Flutter stable. v1 = GTT Turin bus/tram/metro/funicular;
regional buses phase 9 labelled "scheduled only". Italian default + English
switch; follows phone theme, dark tuned first. Google Sans Flex bundled
(verify licence + axes with fonttools before use). Balanced sort: walking
dominates, time breaks near-ties. Max extra time = setting, default +20 min.
Walk cap 800 m adjustable, speed default 1.2 m/s. Max 3 transfers, no wait cap.
Arrive-by supported. Live trip foreground only, screen awake, vibrate on alight.
Approximate data carries an "approximate" marker. Vehicle icons static, from
zoom 12. Arrows only where a segment is used in exactly one direction. Merge
thickness capped at 3x. Unresolvable line path: skipped in ambient, dotted
"approximate" only inside a selected trip. Back steps out one level
(vehicle -> line -> map). Suspended stops excluded from planning; detoured lines
kept, flagged, ranked below equal unflagged. No alert markers on the map.
Advanced/raw-data mode hidden in Settings. Open source (MIT or Apache-2.0
chosen at phase 10). GitHub release APK (github.com/piedemove). No monetisation.

## Definition of done

Golden test + pinned hop tests + `test/trips.yaml` pass. Planner works with
live feeds down and the line network absent. Ambient lines follow streets, use
the right lane on divided roads, merge by shared OSM way with capped thickness,
show two-colour bus/tram segments, open a picker on tap. Selecting a route or
trip removes everything unrelated; clearing restores everything. Every stop,
line, vehicle and alert opens the same sheet from anywhere, and every sheet
drags. Live trip verified on a real ride with a correct alight cue and a
travelled/ahead split. No off-road jogs, gaps or doubled lines in the viewport
tour. README, licence and in-app About complete.

## Known environment facts

- Phone serial changes between sessions: run `adb devices` first.
- `protoc` is NOT installed; needed in phase 3 for the GTFS-RT bindings
  (generate once, commit the Dart output).
- graphify: graph built at the end of phase 1, when there is real code to index.
- Old project: `../piemove-maps`, read-only, data facts only, copy no code.
