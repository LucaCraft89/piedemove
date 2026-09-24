# PiedeMove

Android (Flutter) public-transport planner for Turin, for free-pass holders.
Rides cost nothing, so **walking metres are the cost**: it shows every line that
can make a hop, generates footpath transfers between nearby stops, and trades
waiting and transfers for less walking. Bus, tram, metro, funicular. No fares,
no cars or bikes, no walking-only trips. Fully on-device: no backend, no
account, no tracking, no Google data.

## Install

Download the APK from the [Releases page](https://github.com/LucaCraft89/piedemove/releases)
(latest: `0.9.0-beta.1`, a prerelease), allow installing from unknown sources,
and open it. Report problems in [Issues](https://github.com/LucaCraft89/piedemove/issues).

## Build

    flutter pub get
    flutter analyze && flutter test
    flutter build apk --release
    dart tool/build_index.dart     # GTFS ingest -> index.bin (on first run)

## Known data gaps

- GTT publishes no transfers file: footpaths between stops are estimated.
- The regional (Regione Piemonte) bus feed is schedule-only, no realtime.
- OpenStreetMap footpath and crossing quality varies; approximate data is
  marked in the app.
- Realtime and alerts come from GTT's GTFS-RT feeds and may be missing.

## Licences

Code: MIT (`LICENSE`). Data is **not** MIT; see `NOTICE.md`. In short: GTT data
is for non-commercial use with attribution, so PiedeMove stays free, ad-free
and non-commercial. Map data is © OpenStreetMap contributors (ODbL).
