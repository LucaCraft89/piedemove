---
name: piedemove-release
description: Licensing, data attribution, fair use, the regional-feed phase, and the GitHub APK release checklist. Load for phase 9, phase 10 or any licence/attribution question.
---

# Release

## Phase 9 — regional buses — **done**

Ingest rules and merged-feed numbers live in `piedemove-data`
("Regional feed"). What the UI does with them:

- `RideOption.scheduledOnly` / `Leg.scheduledOnly` carry the flag out of the
  planner; `ScheduledOnlyNote` (`lib/ui/widgets/scheduled_only.dart`) is the
  marker, shown on each scheduled-only trip leg and at the top of the line
  sheet ("Bus extraurbano · solo orario").
- Regional legs have no snapped geometry, so they draw as approximate chords.
- About lists Regione Piemonte, CC-BY 4.0, "senza tempo reale".

## Phase 10 — release

- README with the full description, plus the **truthful** data-gap list: GTT has
  no transfers file, footpaths are estimated, the regional feed has no realtime,
  OSM path quality varies.
- Licence file: MIT or Apache-2.0, chosen at release.
- **Verify each dataset's licence text at release time**, not from memory.
- Confirm the OSM-derived cache stays on-device and is **not redistributed**.
- In-app About complete (see `piedemove-ui` §11.8).
- APK published on GitHub (`github.com/LucaCraft89/piedemove`). No monetisation.
- Then **GATE 3**: final acceptance on the phone by the user.

## Fair use, always

Attribute all data. Cache Overpass, Photon and tile requests. Identify the app
in the User-Agent. **Never use Google Maps data or APIs.** No credentials in
prompts, notes, skills or commits.

## Licences verified 2026-09-24

GTT's own page (gtt.to.it/gtt_gtfs_license.html) is **non-commercial only** with fixed attribution
("Data source: GTT S.p.A. – Gruppo Torinese Trasporti" + link), stricter than the CC-BY on
dati.gov.it/aperTO. So: no ads, no monetisation, ever. Regione Piemonte: CC BY 4.0. OSM-derived
assets: ODbL. Details in `NOTICE.md`.
