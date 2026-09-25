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

## Regional feed (phase 9, scheduled only)

`lib/data/index_merge.dart` — `mergeRegional(gtt, regional)`. Both feeds are
parsed by the same `buildIndex`; the regional one is then folded in:

- a regional stop within **150 m** of a GTT stop *is* that GTT stop (this is
  what creates the cross-feed transfers); the rest are appended;
- a route whose stops are **all** covered is dropped - GTT already plans it;
- ids coming from the regional feed are prefixed `R:`, so no collisions;
- both calendars are rebased onto one service window;
- `routeFeed[route]` is `feedGtt` or `feedRegional`; `ix.isScheduledOnly(route)`
  and `ix.patternScheduledOnly(p)` are the checks everything else uses.
  `shapes.txt` is never read by the index build (183 MB of the 216 MB); only `tool/build_lines.dart` reads it, for the pattern geometry (the shape is the evidence the lines are matched to).

Regional routes are excluded from OSM tiles, the snap corridor and the line
network (`lib/geo/line_build.dart`), so inside a trip they draw as approximate
chords and never appear in the ambient map. Realtime never matches them.

Merged build 2026-09-19: regional feed 653 routes / 70,380 stops (10,506 of
them on a pattern) -> **614 routes kept, 8,768 new stops**; merged index
15,822 stops, 831 routes, 6,880 patterns, 62,610 trips, **18.3 MB**, ~8 s on a
laptop. `dart tool/build_index.dart [--no-regional]`. `indexFormatVersion` is
**2** (adds `routeFeed`); a v1 `index.bin` is rejected and rebuilt.

## Stop clusters — display only

Same cleaned name **and** within 150 m form one cluster. Never group by name
alone: "TRAPANI" is 7 stops in 4 places over 900 m; "PESCHIERA" is 10 stops
including one in Moncalieri. **Routing always uses individual stops.**

## Realtime

**No protoc, no generated bindings.** `lib/realtime/pb.dart` is a ~60-line
protobuf wire reader (`Pb.decode` -> field number -> values);
`lib/realtime/gtfs_rt.dart` pulls the ~20 GTFS-RT fields the app uses out of it.
A malformed entity is dropped, never patched. `dart tool/rt_check.dart` decodes
the three live feeds and prints what came back — run it when a feed looks wrong.

What GTT actually sends (checked 2026-09-19, not what the spec suggests):

- **Vehicle positions** (~20 KB, 355 vehicles): `VehicleDescriptor.id` is the
  fleet number and is unique; `TripDescriptor` carries **`route_id` only — no
  `trip_id`, no `stop_id`, no `current_stop_sequence`**. So a vehicle links to a
  *line*, never to a run: no next stop, no itinerary, no delay for it. Position,
  bearing and `current_status` are present. Poll 20 s.
- **Trip updates** (~68 KB, ~385 trips, all known to the index): keyed by
  **`stop_sequence`, 1-based and contiguous, with no `stop_id`**, a rolling
  window of ~7 stops ahead. Two thirds give `delay`, one third an absolute
  `time` instead; `TripUpdate.delay` is absent. Poll 30 s.
- **Alerts** (~197 KB, ~185 alerts): cause/effect, informed entities, Italian
  translations present. Poll 5 min.

`buildDelayLookup(ix, rt)` turns that into `DelayLookup(trip, position)`:
position `p` is sequence `p + 1`, an absolute `time` becomes a delay against
`start_date` + the scheduled second, and a value **carries forward** to later
stops. Stops outside the window return null and show as scheduled.

`RealtimeController` (`lib/realtime/store.dart`) polls the three feeds on their
own timers, doubles the interval per feed on error up to 5 min, and stops every
feed when the app is not resumed. `FeedHealth` per feed feeds the home chip:
stale = three intervals without a good answer.

## Persistence

`shared_preferences`: settings, favourites, saved places, recents.
Application-support dir: `index.bin`, `lines.bin`, cached Overpass results,
metro entrances. All versioned and all safe to delete — rebuilt on next launch.

## On-device index (phase 2)

`lib/data/index_source.dart` — `IndexStore(dir).load()`: a cached `index.bin`
younger than `maxIndexAge` (7 days) is used as is; otherwise the zip is
downloaded, `buildIndex` runs in an `Isolate.run` (the parse is seconds of CPU
and must never block a frame) and writes `index.bin`. **Any failure falls back
to the cached index** — the planner has to work with every feed down. Coarse
progress only (`IndexStage`): the isolate reports no intermediate stages.

`lib/data/providers.dart` — `transitIndexProvider` (FutureProvider),
`indexStageProvider` (first-run chip), `stopClustersProvider`,
`stopModesProvider` (route types per stop, for the map dot colour).

## Built in phase 1

`lib/data`: `feeds.dart` (URLs), `csv.dart`, `gtfs_zip.dart` (member -> temp
file -> line stream), `index_build.dart`, `transit_index.dart`,
`index_io.dart` (`indexFormatVersion = 2`), `clustering.dart`.
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

## Walking graph (phase 5b-A)
- `dart tool/build_walk.dart [--offline] [--out --manifest --asset --bbox --input]` builds
  `assets/walk_graph.pmwg.gz` from cached Overpass tiles (build/walk_osm); deterministic bytes.
- Format v1 (header: magic, format, OSM time, bbox, payload sha256) and manifest schema: `docs/walk_routing.md`.
- Loader `loadWalkLayers` (walk_graph_update.dart): valid downloaded -> shipped asset -> null.
  Updater: `walkManifestUrl` constant, ETag, 1/day, sha256+format check, atomic rename, silent.

## Audit fixes (2026-09)

- `writeIndexFile` writes `index.bin.tmp` then renames; `readIndexFile` treats
  any decode error (RangeError, FormatException) as "no index" and deletes the
  torn file, so a crash mid-write can never pin a bad index for 7 days.
- Static feeds download through `lib/data/download.dart` (`downloadToFile`):
  streamed to `<path>.part`, renamed on success, 60 s stall timeout between
  chunks (not a total cap - the regional zip is 200+ MB). `tool/build_index`
  uses it too.
- Index format **v3**: `patternSeq` (GTFS stop_sequence per pattern position)
  after `patternStop`; use `ix.stopSequenceAt(p, pos)` for anything realtime
  keyed by sequence (delays, skipped stops, vehicle position) - never `pos+1`.
  A v2 cache reads as missing and is rebuilt on the phone.
- GTFS-RT: `TripDescriptor.schedule_relationship` CANCELED (4 = 3) and
  `StopTimeUpdate.schedule_relationship` SKIPPED (5 = 1) are decoded;
  `unavailableLookupProvider` feeds departures and the planner (today's runs
  only). Every alert `active_period` counts. Realtime fetches time out after
  15 s; vehicles older than 3 min / delays older than 10 min with every poll
  failing since are dropped, not shown as live.
