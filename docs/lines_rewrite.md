# Line geometry rewrite (fix phase 1c)

## Why the old chain failed

Stops were snapped to an edge and each hop routed on its own. Every hop that
could not be routed became a straight chord, so 3.6% of hops (6.7% of the drawn
length, runs up to 34 km) were straight diagonals. Stops split OSM segments at
their own positions, so every pattern cut the network differently: merging by
exact coordinates fragmented, and a stack of cleaners (spur removal, retrace
collapse, kink loops, corner cutting, bus/tram shifting) tried to repair what
the splitting broke, each opening new gaps or eating real curves.

## Design

    GTFS shapes.txt + stop_times + OSM ways
      -> per pattern: resample the shape every 15 m
      -> HMM (Viterbi) over graph-edge candidates, whole pattern at once
      -> one continuous edge sequence (whole OSM segments, stops never split them)
      -> stops placed on the finished path by a monotone DP
      -> lines.bin (per-pattern polyline + stop vertex indices)
      -> merge by physical segment identity (mode, node pair) -> ambient.json

* **Evidence is the GTFS shape**, the true path the vehicle drives. Emission =
  distance to the road + heading against the shape; transition = graph route
  length vs the shape's own arc length (Newson-Krumm). Direction of travel comes
  from the directed graph, so the right carriageway falls out.
* **Graphs.** bus: drivable ways, bus lanes, one-ways (contraflow edges kept at
  a penalty, because real bus lanes are often untagged), tram track at a
  penalty (a "bus" can be a rack line). tram: `railway=tram`. rail: subway,
  funicular, light_rail (one Overpass call over the metro/funicular stops); used
  only when a metro/funicular pattern has no shape. Shapes present: used as is.
* **Failure ladder** for a stretch the model cannot match: wide candidates
  (70 m, beside-the-road only) -> a shortest path hugging the shape (40 m
  corridor, length cap) -> the shape's own polyline, dotted (`approx = 1`), never
  a straight chord. Every dotted stretch is counted with its cause
  (`build/gaps.txt`).
* **Spurs**: a there-and-back stub under 60 m on the finished path is removed
  (by node or by place); longer excursions are real turnarounds and stay.
* **Stops** never modify the network. A stop gets its own vertex in the
  pattern's stored polyline (so focus slicing is exact) but the ambient merge
  works on the edge sequence, where stops do not exist.
* **Merge** by graph segment identity: identical segments across patterns and
  directions collapse; chains break exactly where a route set changes or a
  fork/end is reached. No geometry is moved: no smoothing, no bus/tram shift.
  Tram is drawn before bus and wider (`railWidthFactor`), so on a shared street
  both stay visible.
* **No smoothing.** OSM geometry is already what the basemap draws.

## Checks (all in the repo)

* `tool/gap_detector.dart` + test: every hop of every pattern is covered by a
  drawn feature (0).
* `tool/knot_detector.dart` + test: folds > 150 deg with both legs <= 15 m in
  one drawn line (0).
* `tool/lines_report.dart`: dotted length and runs, longest dotted run, detour
  ratio (path / shape length), path-vs-shape deviation both ways, stop offsets
  monotone, invented spurs.
* `test/lines_unit_test.dart`: synthetic graphs (bent road, oneway pair, loop,
  contraflow, dotted gap, no shape, merge/chain).

## Reproduce

    dart tool/build_index.dart       # only when the GTFS zip changed
    dart tool/build_lines.dart       # ~30 s on cached tiles; fetches missing OSM
