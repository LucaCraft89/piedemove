# Data licences and attribution

The MIT licence in `LICENSE` covers the source code only.

| Data | Source | Terms |
|------|--------|-------|
| Timetables, realtime, alerts | Data source: GTT S.p.A. – Gruppo Torinese Trasporti, https://www.gtt.to.it | GTT GTFS Open Data License (https://www.gtt.to.it/gtt_gtfs_license.html): **non-commercial use only**, attribution as written here, no warranty. No resale, paid services or advertising-based apps without GTT's written authorisation. |
| Regional bus timetables | Regione Piemonte | CC BY 4.0 |
| Streets, tracks, footpaths, metro entrances | © OpenStreetMap contributors | ODbL 1.0 (https://www.openstreetmap.org/copyright) |
| Base map | OpenFreeMap, OpenMapTiles, OpenStreetMap data | see https://openfreemap.org/ |
| Place search | Photon (Komoot), OpenStreetMap data | public API, fair use |
| Font | Google Sans Flex | SIL OFL 1.1 (`assets/fonts/OFL.txt`) |

## Bundled derived data (`assets/`)

`walk_graph.pmwg.gz`, `ambient.json.gz`, `connectors.json.gz`,
`entrances.json.gz` and `lines.bin.gz` are derived from OpenStreetMap
(ODbL 1.0, share-alike: these files stay under ODbL). `lines.bin.gz`,
`ambient.json.gz` and `connectors.json.gz` also derive from GTT line data, so
the GTT non-commercial terms apply to them too. The `walk-graph-latest` release
carries the same OSM-derived walking graph under ODbL.

Reuse of these files, or of the app, for a commercial purpose needs GTT's
written authorisation.
