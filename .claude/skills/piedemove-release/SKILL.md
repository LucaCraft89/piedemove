---
name: piedemove-release
description: Licensing, data attribution, fair use, the regional-feed phase, and the GitHub APK release checklist. Load for phase 9, phase 10 or any licence/attribution question.
---

# Release

## Phase 9 — regional buses

Ingest the Regione Piemonte GTFS (see `piedemove-data` for the URL).

- Mark a regional stop `gttCovered` if a GTT stop is within 150 m.
- **Drop any regional route whose stops are all covered.**
- Snap covered stops onto their GTT stop — this is what creates the cross-feed
  transfers.
- **Skip `shapes.txt` entirely**: 183 MB of the 216 MB.
- Regional legs draw as chords with the approximate marker and show a
  "no live data" marker. Label the mode "scheduled only".

## Phase 10 — release

- README with the full description, plus the **truthful** data-gap list: GTT has
  no transfers file, footpaths are estimated, the regional feed has no realtime,
  OSM path quality varies.
- Licence file: MIT or Apache-2.0, chosen at release.
- **Verify each dataset's licence text at release time**, not from memory.
- Confirm the OSM-derived cache stays on-device and is **not redistributed**.
- In-app About complete (see `piedemove-ui` §11.8).
- APK published on GitHub (`github.com/piedemove`). No monetisation.
- Then **GATE 3**: final acceptance on the phone by the user.

## Fair use, always

Attribute all data. Cache Overpass, Photon and tile requests. Identify the app
in the User-Agent. **Never use Google Maps data or APIs.** No credentials in
prompts, notes, skills or commits.
