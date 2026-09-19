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

Phase 7 needs a real walk + bus ride. **State clearly which parts were verified
on the road and which only by code.**
