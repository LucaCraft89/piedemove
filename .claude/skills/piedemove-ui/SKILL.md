---
name: piedemove-ui
description: Visual direction, palette and typography tokens, home screen, search, trip results and detail, the one entity-sheet system, settings, accessibility, and the design gate. Load for anything in lib/ui or lib/settings, or when preparing GATE 1 samples.
---

# UI

## Direction

A mix of Google Maps' devices and PiedeMove's identity. **Take from Maps**:
coloured line-badge pills with a mode icon, delay and status chips, detour
banner, previous/next-departure rows, key info that pops. **Keep from
PiedeMove**: walking metres as a first-class figure, transport only. Not a Maps
clone — no price, no car/foot/bike tabs.

- Airy: 16 dp screen padding, 12 dp between elements, >= 48 dp rows, never more
  than three competing pieces of information on one line.
- **Google Sans Flex only**, bundled. Verify its licence text and axes with
  `fonttools` before use. Use the width axis for condensed data (times,
  distances) if present, otherwise a second static weight.
- Every walk figure is readable — **never grey**. Colour per the 3-tier walk
  scale in `piedemove-lines` §9.10.
- Live info always stands out: a **LIVE** chip with a pulsing dot in a saturated
  colour, versus a plain muted **Programmato** for schedule.
- Palette tokens defined once in `lib/ui/theme/`. Defaults, approved at GATE 1:
  bus green, tram orange, metro red, funicular purple, regional teal — each with
  a dark variant. Follows the phone theme; **dark is tuned first**.
- Line badge: coloured pill, Material mode icon, line number only.

## Home (§11.2)

Full-screen map. Top search bar with a swap origin/destination button. Under it
a row of small pills: **Veicoli · Avvisi · Filtri · Linee · Impostazioni**.
My-position button bottom-right, **in the corner**, not floating mid-edge.

Nothing selected: all live vehicles and ambient lines visible; the bottom sheet
lists next arrivals at nearby stops (within 400 m, top departures per stop),
soonest first, plus favourites. After planning, the trip sheet appears; closing
it leaves a reopen chip and a clear-trip control. **Clearing must redraw the
ambient network fully and correctly — regression-test on device.** A feed-health
chip appears when any feed is stale.

## Search (§11.3)

One box, sectioned results: places, stops, lines, vehicles.

- **Places**: Photon. Debounce 300 ms, min 3 chars, cancel stale requests, cache,
  bias to the user's location, bound to Piemonte. Sorted by distance from the
  user. Show the **full street address** (street, number, city), never the
  district. Highlighting a result pins it on the map.
- **Stops**: local index, diacritic-insensitive prefix and token match; each
  result shows address and the lines serving it.
- **Lines**: by number or name, opening the line sheet with the whole itinerary.
- **Vehicles**: by fleet id or label from the live feed.
- Recents and saved places (Home, Politecnico, custom) stored locally.
  "My location" is the default origin. Attribute Photon/OSM in About.

## Trip planning and results (§11.4)

Inputs: from, to, swap, when (now / depart at / arrive by).

Result card: departure -> arrival, total duration, "leaves in N min" live
countdown, next departure, coloured walking chip in metres, **one badge per leg
showing every serving line (33 · 42 · 68)**, delay chips, detour banner.
Arrival time and duration lead the line; walking is a bold coloured chip beside
them. A connection under 2 minutes gets a warning chip. Tabs: **Più veloce** and
**Bilanciato**. Active network alerts show as a compact banner above the list
that opens the full list. The only limit is the max-extra-minutes setting
(default +20) — no global cap.

## Detail pages: one system (§11.5)

Four entity kinds: **Line, Stop, Vehicle, Alert**. Implement **one `EntityRef`
type and one `openEntity(EntityRef)`**. Every tap site — map, popups, search,
trip steps, other detail pages, home list — calls it. No widget builds its own
navigation. A navigation stack backs it; back steps out one level.

- **Line**: full itinerary in order with a direction toggle, next arrivals,
  first/last departure and frequency, live vehicles on it (tap -> vehicle),
  alerts, favourite toggle. Highlights on the map in focus mode.
- **Stop**: next arrivals soonest first, line filter chips + text filter, lines
  serving it (tap -> line), metro entrances, alerts, favourite toggle. Each row:
  line badge, headsign, "N min", LIVE chip when live.
- **Vehicle**: line number only (**no "Vettura"**), headsign/direction, current
  status, next stop (tappable), delay, full itinerary with the vehicle's
  position marked. Jump to line or stop. Live status stands out.
- **Alert**: full text, cause, effect, affected lines and stops (tappable),
  active period.

**Every sheet is a `DraggableScrollableSheet`** with snaps at ~15%, ~50%, ~92% —
including the trip results list. Each sheet body sits in a `SafeArea(top:
false)`: without it the last row hides under the system navigation bar.

## Trip detail (§11.6)

Steps: walk, ride, transfer, ride, walk.
- **Ride**: header with badge(s) and headsign; collapsed "N fermate" expanding
  to intermediate stops with live times; the current or just-passed stop
  highlighted when the vehicle is live; alternative lines with next departures;
  tap-through on every element.
- **Walk**: readable colour, distance and time. **Transfer**: walking metres and
  time to the next stop.
- Header has Recalculate and Start trip.

## Map layers, bottom to top (§10.1)

basemap -> ambient casings -> ambient lines -> chevrons -> connectors -> journey
context -> journey ride (travelled/ahead) -> journey walk (travelled/ahead) ->
stop clusters -> stop poles -> stop labels -> metro entrances -> vehicle halos ->
vehicle icons -> user location -> search pin. **Every layer add is isolated.**

- **Stops**: clusters below z15, individual poles from z15 (two TRAPANI poles
  150 m apart must stay separate). Labels = cleaned name with a halo, **constant
  opacity at every zoom — never fade**. `symbol-sort-key` so journey stops win
  collisions; journey stops use `text-allow-overlap`. Dot colour by served mode
  (metro > tram > bus for mixed, or a split ring). Suspended stops grey with a
  warning glyph. Tap targets >= 44 px via an invisible larger circle layer.
- **Vehicles**: one sprite per mode, generated at startup by drawing the Material
  icon onto a canvas then `addImage`. Black filled circle, outer ring in the
  mode colour, white icon, **icon noticeably larger than the old version**, white
  halo layer underneath. Size interpolates ~0.8 at z11 to ~1.6 at z17. Shown from
  z12 when nothing is selected (all vehicles); when a line/trip/route is
  selected, only relevant ones. Tap -> vehicle sheet, target >= 44 px.
- **User location**: dot with accuracy ring. A search result drops a pin showing
  the full address so the user can confirm before choosing it.
- **Metro entrances** (§10.5): one Overpass query
  `node(around:150,lat,lon)[railway=subway_entrance]` unioned over every metro
  stop, cached 30 days. Small circles with labels in the metro colour from z15,
  also listed on the metro stop sheet.

## Settings (§11.7)

Max extra time; walking cap; walk speed (slow/normal/fast/custom); minimum
transfer time; modes included; language; theme; data status (per-feed last fetch
+ refresh); advanced/raw-data mode.

**Raw-data mode**: every stop, leg, vehicle and alert gains a "raw" expander
showing the record verbatim; long-press copies JSON. A feed-status screen lists
each source URL, HTTP status, bytes, `feed_version`, last fetch, next refresh.

## About (§11.8)

GTT open data (CC-BY), OpenStreetMap contributors (ODbL), OpenFreeMap and
OpenMapTiles, Photon by Komoot, later Regione Piemonte (CC-BY 4.0). State that
no Google data or APIs are used. App licence.

## Accessibility (§14)

Tap targets >= 44 px. Contrast checked in both themes. All icons labelled. Text
scales with the system font size without clipping. **No information by colour
alone** — badges also carry the line number and icon.

## GATE 1

Show the user static samples built from **real data**: line style and UI
(results card, stop sheet, vehicle sheet, palette, walk tiers) at three spots —
a corso with two carriageways, a bus/tram shared street, a plain street. Wait
for approval of look, palette and line style before phase 6.

## Built in phase 2 (shell, map, stops)

- `lib/ui/theme/tokens.dart`: `PmTokens` theme extension — `ModeColors`,
  `WalkColors` (3 tiers), `live`, and `Gap` (screen 16, element 12, row 48,
  tapTarget 44). Read with `context.tokens`. `app_theme.dart` builds the two
  themes.
- **Google Sans Flex is bundled** (`assets/fonts/GoogleSansFlex.ttf`, OFL 1.1,
  verified with fonttools: axes wght 1-1000, wdth 25-151, opsz, GRAD, ROND,
  slnt). One variable file, so every `TextTheme` style carries an explicit
  `FontVariation('wght', ...)` — Flutter fakes the weight otherwise.
  `pmCondensed(style)` adds the width axis for times and distances.
- `lib/ui/map/map_view.dart`: MapLibre (`maplibre_gl` 0.27) over OpenFreeMap —
  `styles/dark` when the phone is dark, `styles/positron` when light. The stop
  source is one clustered GeoJSON source (`pm-stops`), rebuilt with
  `setGeoJsonSource` when the index arrives after the style. Layers, each in
  its own try/catch feeding `mapStatusProvider`: `pm-stop-clusters` (circle,
  coloured by the cluster's most distinctive mode from the `b`/`t`/`m`/`f`
  flags aggregated with `max`; a split-pie **sprite** was tried and dropped —
  maplibre-native never showed the registered images),
  `pm-stop-cluster-count`, `pm-stop-touch` (invisible r=22 tap target),
  `pm-stop-poles`, `pm-stop-labels`. Poles and labels from `poleMinZoom` 15,
  clusters below it (`clusterMaxZoom` 14), labels at constant opacity.
- `lib/ui/home/home_page.dart`: search bar (live from phase 4), pill row,
  my-position FAB in the corner, index/map status chips, nearby sheet.
- `lib/ui/sheets/`: `nearby_sheet.dart` (stops within 400 m, 3 departures each,
  snaps 0.15/0.5/0.92) and `stop_sheet.dart` — a placeholder with one call site,
  `showStopSheet(context, stop)`, that phase 3 swaps for `openEntity`.
- `lib/ui/widgets/`: `line_badge.dart`, `departure_row.dart`.
- `lib/location/device_location.dart`: `locateMe()` — permission, one fix,
  never throws; callers keep working with a null position.

## Built in phase 3 (realtime, vehicles, entity sheets)

- `lib/ui/nav/entity.dart`: `EntityRef` (`StopRef`, `LineRef`, `VehicleRef`,
  `AlertRef`), `entityNavProvider` (the stack) and **`openEntity(context, ref,
  ref)`** — the only way a sheet opens. One modal `DraggableScrollableSheet`
  (0.15/0.5/0.92) hosts every body; `PopScope` makes back step out one level and
  close at the bottom.
- `lib/ui/sheets/`: `stop_sheet.dart` (alerts, line filter chips, live
  departures, lines), `line_sheet.dart` (alerts, Andata/Ritorno toggle, today's
  span + median headway, live vehicles, itinerary; also exports `StopStep` and
  `statusLabel`), `vehicle_sheet.dart` (line badge, LIVE chip, delay, itinerary —
  degrades to line-only because GTT sends no trip id), `alert_sheet.dart` (text,
  cause/effect chips, affected lines/stops, plus `showAlertList` behind the
  Avvisi pill), `sheet_parts.dart` (`SheetHeader` with back, `Grabber`,
  `AlertTiles`, `SheetSection`).
- Map: `lib/ui/map/vehicle_features.dart` draws one PNG sprite per mode at
  startup (`addImage('pm-veh-<mode>')`) — black disc, mode-colour ring, white
  glyph — and builds the GeoJSON; feature id is the list position, mapped back to
  the vehicle id on tap. Layers `pm-vehicle-halos`, `pm-vehicle-icons`
  (iconSize 0.8 at z11 to 1.6 at z17), `pm-vehicle-touch` (r=22), all from z12,
  all in one try/catch. `vehiclesVisibleProvider` is the Veicoli pill.
- Home: stop and vehicle taps call `openEntity`; the Avvisi pill shows the live
  alert count; a chip appears when realtime feeds go stale.

## Built in phase 4 (search)

- `lib/places/photon.dart`: `PhotonClient.search` — Piemonte bbox
  (6.6,44.0,9.3,46.6), location bias, `limit` 8, in-memory cache keyed by the
  folded query, throws on failure. **Two facts the API forces:** `lang=it` is
  rejected (`default`/`de`/`en`/`fr` only, use `default` to keep Italian names)
  and a missing `User-Agent` gets **403** — send `userAgent`. `Place.fromFeature`
  builds the full street address (`street housenumber, city`), never the
  district, and drops features without a point.
- `lib/places/search_index.dart`: `fold` (diacritics + case), `matchesQuery`
  (every query token must prefix a target token), `searchStops` (nearest first,
  poles no line serves skipped), `searchRoutes` (exact short name first, then
  numeric), `searchVehicles` (fleet id or label). All pure: search works with
  every feed down.
- `lib/places/saved.dart`: `recentPlacesProvider` (cap 10) and
  `savedPlacesProvider` — `PlaceList` over SharedPreferences JSON, corrupt data
  resets instead of breaking the box. Also `selectedPlaceProvider` (the pin) and
  `photonClientProvider`.
- `lib/ui/search/search_page.dart`: `openSearch(context)` pushes it. 300 ms
  debounce, min 3 chars, a ticket counter drops stale replies, Photon failure
  shows one tile and leaves the local sections working. Empty query lists "La
  mia posizione", Salvati, Recenti; a star toggles saved. Stop/line/vehicle rows
  call `openEntity`; a place pins and recentres the map.
- Map: the pin is **one circle annotation** (`addCircle`/`clearCircles`), not a
  layer — `_updatePin` in `map_view.dart`, isolated like every layer.
- A GTT pole has no street address in GTFS: the stop row shows
  `Fermata <code> · <metres>` plus the line badges instead.
- `TransitIndex.routesAt(stop)` is the shared "lines serving this stop" helper
  (stop sheet and search both use it).

## Built in phase 5 (planning UI, settings)

- `lib/settings/settings.dart`: `PmSettings` (max extra minutes, walk cap, walk
  speed, min transfer, modes, theme) + `settingsProvider`, persisted as one JSON
  blob in SharedPreferences; a corrupt or older shape resets to the defaults.
  `toggleMode` never lets the last mode go off. Language stays Italian: the
  switch needs l10n, which no phase has done yet.
- `lib/ui/trip/trip_plan.dart`: `TripQuery` (from/to as `Place`, `WhenMode` now /
  departAt / arriveBy), `TripState` (result, tab, selected leg card, sheet
  hidden) and `TripPlanController`. **Planning is an explicit action**, never a
  watch — the alert filters and live feeds change every few seconds and a search
  must not rerun under the user. `planRequestFor` is pure and pinned by tests.
- `lib/ui/trip/trip_format.dart`: `hhmm`, `durationLabel`, `metresLabel`,
  `leavesInLabel`, `legLines`, `tightConnection` (< 120 s), `transfersLabel`.
- `lib/ui/trip/trip_sheet.dart`: one `DraggableScrollableSheet` (0.15/0.5/0.92)
  holding both the results list and the trip detail — detail is the same sheet
  with a back arrow, so there is one navigation model. Cards lead with
  `hh:mm → hh:mm`, duration and a coloured walk chip, then the full badge chain
  (every serving line), then countdown, transfers, delay and "cambio stretto".
  Alert banner above the tabs (Più veloce / Bilanciato). A 20 s timer ticks the
  countdowns. Detail: Ricalcola + Avvia (Avvia is phase 7), walk/transfer steps,
  ride steps with expandable "N fermate" and the other lines for the same hop.
- `lib/ui/home/home_page.dart`: `_PlannerCard` (from, to, swap, when chips,
  Cerca). Empty origin means "La mia posizione". The trip sheet replaces the
  nearby sheet while a result is up; closing it leaves **Mostra i percorsi** and
  **Cancella** chips. Pills: Cerca, Veicoli, Avvisi, Filtri, Impostazioni wired;
  Linee waits for phase 6.
- `lib/ui/settings/settings_page.dart`: `openSettings` (page) and `showFilters`
  (the Filtri pill) share one `PlanningControls` widget; in the Filtri sheet a
  change replans immediately. Data status lists the index version and each live
  feed's last fetch, HTTP status, bytes and a refresh button.
- `openSearch(context, pick: true)` turns the search page into a place chooser:
  it answers a `Place` (a stop becomes one at its coordinates) and hides the
  line and vehicle sections.
- The journey is **not drawn on the map yet** — journey geometry belongs to the
  line work in phase 6.

## Built in phase 8 (entrances, favourites, raw data, About)

- **Metro entrances** are a *desktop-built asset*, not a runtime Overpass query:
  `dart tool/fetch_entrances.dart` unions `node(around:150,…)
  [railway=subway_entrance]` over the metro stops of `build/index.bin` and
  writes `assets/entrances.json.gz` (85 points, 1.2 kB). The phone only loads
  it, through `metroEntrancesProvider` in `lib/geo/line_providers.dart`. Re-run
  the tool when the metro changes; there is no cache to expire.
  `map_view._addEntrances` draws dots + labels in the metro colour from z15, in
  its own try/catch. `entrancesNear` in `stop_sheet.dart` lists the ones within
  150 m on a metro stop sheet.
- **Favourites** (`lib/places/favourites.dart`): one `Set<String>` in
  SharedPreferences, keyed `stop:<gtfs stop_id>` / `line:<short name>` — never
  by index, which moves with every feed rebuild. `FavouriteButton` is the
  `trailing` of `SheetHeader` on the stop and line sheets; the nearby sheet puts
  favourite stops above the nearby ones ("Preferiti" / "Vicino a te").
- **Raw-data mode**: `PmSettings.advanced`. `RawData` in `sheet_parts.dart` is
  self-gating (nothing rendered when the mode is off) and long-press copies the
  record; stop, line, vehicle and alert sheets each end with one. Settings gains
  the switch plus `_FeedSources`, every feed URL verbatim.
- **About**: `lib/ui/settings/about_page.dart` — GTT CC-BY, OSM ODbL,
  OpenFreeMap/OpenMapTiles, Photon, Regione Piemonte, "no Google data or APIs",
  licence and version. Both Settings and About wrap the list in a
  `SafeArea(top: false)`: the last row was landing under the navigation bar.

## Built in fix phase 2 (focus survives everything)

- `FocusController` (`lib/ui/map/map_focus.dart`, `focusProvider`) is the only owner of `MapFocus?` (route | journey). It *sets* focus by listening to `entityNavProvider` (top is Line/Vehicle) and to the selected trip journey; it *clears* only via `close()` (sheet X, `SheetHeader`) and `cancella()` (top pill). Stop/alert sheets, minimise, pan/zoom, realtime ticks never touch it.
- Entity sheet is no longer modal: `openEntity` pushes onto the stack (popping any search/picker route first) and `HomePage` draws `EntitySheet` over the map. Snaps `sheetPeek/Half/Full` (map_style.dart); rests at peek for line/vehicle, half for stop/alert. `SheetHeader` has the X (`onClose` overrides).
- `_CancellaPill` in home_page: shown whenever focus is set; a live trip asks "Terminare il viaggio?" first (code-only verified, needs a real trip).
- Map: focus has its own source `pm-focus-lines` + layers `pm-focus-casing/-lines/-approx/-arrows` (`focusWidth()` puts `zoom` at the top level). While focused the ambient layers (`_ambientLayers`) are hidden, never re-sourced, so no tiering runs; clearing focus flips visibility back. Fit camera once per new focus, bottom padding = peek.
- On-device lessons: give every feature every property a style reads (`approx`, `travelled` default 0 in `_line`); focus stop dots shrink when zoomed out (`focusDotByZoom`) or their rings hide the route line at city zoom.
- Feed drift: `lineNetworkProvider` returns null when the phone's downloaded feed differs from `assets/lines.bin.gz`; focus then has no geometry. Rebuild with `dart tool/build_index.dart --force && dart tool/build_lines.dart`.
