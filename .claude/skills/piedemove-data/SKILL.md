---
name: piedemove-data
description: GTT/Piemonte feed URLs and facts, streaming GTFS ingest, the binary index format, stop ids and clustering, and the GTFS-realtime pipeline. Load when touching lib/data, lib/realtime, tool/build_index.dart, or when you need a stop id, a feed URL or a polling interval.
---

# Data: feeds, index, realtime

## Sources (verified 2026-09-17)

| What | URL | Notes |
|---|---|---|
| GTT static GTFS | `https://www.gtt.to.it/open_data/gtt_gtfs.zip` | 15.8 MB zip / 99 MB unzipped, CC-BY, no CORS, regenerated daily (`feed_version`) |
| GTT trip updates | `https://percorsieorari.gtt.to.it/das_gtfsrt/trip_update.aspx` | ~61 KB |
| GTT vehicle positions | `https://percorsieorari.gtt.to.it/das_gtfsrt/vehicle_position.aspx` | ~31 KB |
| GTT alerts | `https://percorsieorari.gtt.to.it/das_gtfsrt/alerts.aspx` | ~191 KB |
| Regione Piemonte GTFS (phase 9) | `https://api.smartdatanet.it/api/Servizioprogrammatodeltrasportopubblicoregionepiemonteautobus_22942/attachment/22941/1/GTFS_BUS_IT_PIE.zip` | 50 MB zip / 216 MB, CC-BY 4.0, no realtime |
| Basemap | `https://tiles.openfreemap.org/styles/liberty` | no key |
| Place search | Photon, `photon.komoot.io` | no key. **Never Nominatim** (403 to generic clients) |
| Roads, tram tracks, metro entrances | Overpass (OSM) | fetched once, cached; see `piedemove-lines` |

Feeds move. A smoke test asserts each GTT URL returns 200 with a decodable
payload. `opendata.5t.torino.it` and the aperTO-listed URLs are dead.

## GTT facts

4 agencies, 217 routes (9 tram, 1 metro, 205 bus, 1 funicular), 7,056 stops,
44,740 trips, 1,325,706 stop_times. **No `transfers.txt`. No `parent_station`**
(2 stops excepted). Every `stop_name` is unique: `"Fermata 872 - TRAPANI"`.
Strip display names with `^Fermata \S+ - `. Keep `stop_code` — it is the public
pole number shown on the pole.

### Stop table (used by tests)

| Stop | stop_id / code | coords | lines |
|---|---|---|---|
| POLITECNICO (c. Duca degli Abruzzi) | 2829 / 3454 (376 / 670) | 45.0626, 7.6630 | 10, 33, 58, 91, W15 |
| TRAPANI | 3693 / 3694 (871 / 872) | 45.0692, 7.6376 | 33, 42, 68 |
| PESCHIERA | 230 / 241 (120 / 121) | 45.0694, 7.6388 | 2, 1085 |
| BARDONECCHIA | 208 / 219 (118 / 119) | 45.0721, 7.6408 | 2, 22 |

TRAPANI 872 -> PESCHIERA 120 is 126 m. BARDONECCHIA 119 -> Via Cristalliera is
320 m. Destination: 45.0738, 7.6400.

## Ingest

- **Streaming.** Never decompress a whole zip member into memory: streaming
  inflate feeding a line parser. Peak under ~300 MB on a mid-range phone.
- Whole build runs in an isolate with progress messages for a first-launch
  progress screen. A few minutes is acceptable.
- Index lives in **typed arrays**, persisted to the documents dir as a binary
  file with a **format version**. Old version -> reject and rebuild.
- CSR-style arrays: pattern -> stop sequence, pattern -> trips, per-trip
  departure/arrival seconds, per-stop pattern postings, service bitmasks built
  from `calendar` + `calendar_dates`.
- **Pattern** = unique (route, direction, stop sequence).
- Refresh weekly on Wi-Fi and on `feed_version` change. The app stays usable on
  the cached index while refreshing.

## Stop clusters — display only

Same cleaned name **and** within 150 m form one cluster. Never group by name
alone: "TRAPANI" is 7 stops in 4 places over 900 m; "PESCHIERA" is 10 stops
including one in Moncalieri. **Routing always uses individual stops.**

## Realtime

Dart bindings generated from `gtfs-realtime.proto` with `protoc` + the
`protobuf` package, **committed** to the repo. (`protoc` is not installed on
this machine yet.)

- **Vehicle positions**: poll every 20 s while the map is visible. Fields: vehicle
  id/label, trip id, lat/lon, bearing, `current_stop_sequence`, `current_status`,
  timestamp. Vehicle -> pattern link comes from its trip id. "Next stop" derives
  from `current_stop_sequence` + status (INCOMING_AT / STOPPED_AT / IN_TRANSIT_TO).
- **Trip updates**: poll every 30 s while a trip, line, stop or vehicle sheet is
  open. Delays are offsets onto the static index; a `stop_time_update` delay
  **carries forward** to later stops until the next update.
- **Alerts**: poll every 5 min. Read cause, effect, active periods, informed
  entities (route/stop/trip), translations (prefer Italian, fall back to any).
- Pause all polling when backgrounded. Backoff on error. Track last-success per
  feed; expose it in the feed-health chip and the Settings data screen.
- Regional legs and any leg without realtime show scheduled times with a
  "no live data" marker.

## Persistence

`shared_preferences`: settings, favourites, saved places, recents.
Documents dir: `index.bin`, `lines.bin`, cached Overpass results, metro
entrances. All versioned and all safe to delete — rebuilt on next launch.

## Built in phase 1

`lib/data`: `feeds.dart` (URLs), `csv.dart`, `gtfs_zip.dart` (member -> temp
file -> line stream), `index_build.dart`, `transit_index.dart`,
`index_io.dart` (`indexFormatVersion = 1`), `clustering.dart`.
`dart tool/build_index.dart` downloads to `build/gtt_gtfs.zip`, writes
`build/index.bin`. Both are gitignored; tests skip when the index is missing.

Feed facts as built on 2026-09-19 (`feed_version` 20260919):
7,054 boardable stops, 217 routes, **1,433 patterns**, 44,653 trips,
723 services over 136 days, index **12.6 MB**, build **~4 s** on a laptop.

- **`stop_times.txt` is ordered by stop, not by trip.** A trip's rows are
  scattered over 83 MB, so a one-pass "flush on trip change" parser keeps ~50
  trips and silently throws the feed away. The builder makes two streaming
  passes: count rows per trip, then fill a CSR table sorted per trip by
  `stop_sequence`. Peak ~40 MB of typed arrays.
- Stops with `location_type != 0` are dropped (stations, entrances).
- Trips without a usable time or with a broken sequence are dropped, never
  patched.
- Feed smoke test: `PIEDEMOVE_NETWORK=1 flutter test test/feeds_smoke_test.dart`.
  All four GTT URLs answered 200 on 2026-09-19.
