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
including the trip results list.

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
