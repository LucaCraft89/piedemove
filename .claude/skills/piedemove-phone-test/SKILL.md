---
name: piedemove-phone-test
description: On-device verification - adb, build/install, screenshot discipline, the fixed viewport tour - plus live trip mode (§12) which can only be verified on a real ride. Load before any device check or when working on lib/location.
---

# Phone testing

**On-device screenshots are the only visual verification.** Map screens render
as nothing in widget tests (platform view).

## adb

The phone changes between sessions — **always** start with:

    adb devices          # pick whatever serial is attached

If a feed fails, check DNS/connectivity before touching code. Nothing here
needs sudo; if something does, ask the user to run it.

## Build, install, look

    flutter analyze
    flutter test
    flutter build apk --release
    flutter install -d <serial>
    adb -s <serial> exec-out screencap -p > /tmp/shot.png

Then **downscale to ~720 px wide (or crop to the area of interest) and actually
look at the image.** One screenshot per check, taken only after the build
finishes. Never include a full-resolution capture. No re-screenshot loops: take
it once, read it, decide.

Each phase captures the screens listed in its acceptance criteria.

## Viewport tour (lines)

Scripted, fixed viewports: a corso with dual carriageways; a shared bus/tram
street; the Peschiera/Racconigi corridor; a loop route's turnaround; the city
centre at z12, z14 and z16. Inspect each for: gaps, off-road segments, doubled
lines, missing lines, wrong colours, wrong direction lane.

## Live trip mode (§12)

Started from the trip detail. **Foreground only**: `getPositionStream` while the
app is resumed, cancelled on pause, re-synced on resume. Screen kept awake with
`wakelock_plus` for the trip. No background service.

- **The rider's position drives progress**, not the vehicle's. The vehicle's
  GTFS-RT position stays a separate concept.
- Persistent compact strip: "Scendi a &lt;stop&gt; tra N fermate", or "tra N m" on
  walk legs (distance to leg end).
- **Boarding**: advance walk -> ride when the rider is within 40 m of the
  boarding stop *and* either near the matched live vehicle or moving faster than
  walking speed along the leg. Always offer manual **"Sono salito" / "Sono
  sceso"**.
- **Alighting**: vibrate when one stop remains and again at the alight stop.
  Advance to the next leg within 60 m of the alight stop (walk legs: 25 m of
  their end).
- **Poor GPS** (accuracy > 50 m, or no fix for 20 s — metro, tunnels): fall back
  to the vehicle's live position if known, else schedule-based estimation,
  labelled **"posizione stimata"**.
- **Off route / missed connection**: more than 150 m from the leg path for 30 s
  while riding, or the boarding vehicle has departed -> a one-tap **"Ricalcola"**
  banner. **Never recalculate silently.**
- Progress is monotone; map layers show travelled vs ahead live (see
  `piedemove-lines` §9.11).
- Leave a comment where sensor fusion would go: none is done.

### As built (phase 7)

`lib/location/live_trip.dart` holds the rules as pure functions —
`buildLiveRoute`, `advanceLive`, `staleLive`, `nextLeg` — with
`LiveTripController` wiring geolocator, `HapticFeedback.vibrate()` and
`wakelock_plus` around them. Thresholds are the constants at the top of that
file. The strip is `lib/ui/trip/live_strip.dart`; home swaps it in for the trip
sheet while a trip runs. The travelled/ahead split is `travelled = 1/0` in
`journeyFocusLines` / `walkFeatures`, painted at 0.4 opacity in `map_view`;
`test/live_trip_test.dart` pins the progress rules on a synthetic line.

Progress is vertex-granular on the snapped polyline, and no sensor fusion is
done — both marked `ponytail:` in the source.

Phase 7 needs a real walk + bus ride. **State clearly which parts were verified
on the road and which only by code.**

Verified stationary on 2026-09-19 (db4ae341): Avvia starts the trip, the strip
replaces the sheet, the ride leg reads "Scendi a TRAPANI tra 6 fermate" with
"posizione stimata" on a poor indoor fix, and the manual button and close work.
**Not yet on the road**: boarding detection, the two alight vibrations, the
off-route banner, the metro/tunnel fallback, travelled-vs-ahead as it moves.

## Position dot checks (fix phase 4)

Grant/revoke: `adb shell pm grant|revoke <pkg> android.permission.ACCESS_FINE_LOCATION` (+ COARSE), then relaunch. Theme reload: `adb shell cmd uimode night no|yes`. Recentre: swipe the map, tap the FAB at (975,1935) on a 1080x2400 screen. Verified 2026-09-24: first-launch prompt, chip after "Don't allow", chip re-prompts, dot survives theme toggle, FAB recentres. Not verified: heading wedge (needs movement), services-off path, permanent-denial settings jump.

## Progress engine (fix phase 6a, code/replay only)

`lib/location/live_trip.dart` is the one progress engine: `advanceLive` projects the fix onto segments (`projectAhead`, forward-only, 60 m cutoff keeps progress + "estimated"), state carries `along` metres. Pure helpers: `splitLeg` (travelled/ahead, joined at the dot), `walkStripText`, `nextManeuver`, `rerouteWalkLeg` (WalkRouter.reroute). Tests: `test/progress_test.dart` (incl. noisy replay). Not on a device: strip UI and fade are 6b.
