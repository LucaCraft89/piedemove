/// Footpath transfers between stops, and access/egress edges from arbitrary
/// coordinates.
///
/// Ceiling: there is no pedestrian graph. Distances are straight-line times a
/// detour factor, so footpaths are wrong across the rail yards and the Po.
/// Upgrade path: reuse the OSM road graph from phase 6 once it exists.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:piedemove/data/clustering.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/distance.dart';

/// Straight-line metres are multiplied by this to approximate street walking.
const walkDetourFactor = 1.35;
const defaultWalkSpeed = 1.2; // m/s
const footpathRadiusMetres = 400.0;

/// Seconds to walk [metres] of straight-line distance.
int walkSeconds(double metres, {double walkSpeed = defaultWalkSpeed}) =>
    (metres * walkDetourFactor / walkSpeed).round();

/// Uniform grid over stop coordinates, ~one cell per [cellMetres].
class StopGrid {
  StopGrid(this.ix, {this.cellMetres = 400}) {
    for (var s = 0; s < ix.stopCount; s++) {
      _cells.putIfAbsent(_key(ix.stopLat[s], ix.stopLon[s]), () => []).add(s);
    }
  }

  final TransitIndex ix;
  final double cellMetres;
  final _cells = <int, List<int>>{};

  double get _latStep => cellMetres / 111320.0;

  double _lonStep(double lat) =>
      cellMetres / (111320.0 * math.max(0.2, math.cos(lat * math.pi / 180)));

  int _key(double lat, double lon) {
    final y = (lat / _latStep).floor();
    final x = (lon / _lonStep(lat)).floor();
    return y * 100000 + x;
  }

  /// Stop indices within [radius] metres of the coordinate, with distances.
  List<(int, double)> near(double lat, double lon, double radius) {
    final out = <(int, double)>[];
    final cells = (radius / cellMetres).ceil();
    final y = (lat / _latStep).floor();
    final x = (lon / _lonStep(lat)).floor();
    for (var dy = -cells; dy <= cells; dy++) {
      for (var dx = -cells; dx <= cells; dx++) {
        final bucket = _cells[(y + dy) * 100000 + (x + dx)];
        if (bucket == null) continue;
        for (final s in bucket) {
          final d =
              haversineMetres(lat, lon, ix.stopLat[s], ix.stopLon[s]);
          if (d <= radius) out.add((s, d));
        }
      }
    }
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out;
  }
}

/// CSR table of stop -> reachable stops on foot.
class Footpaths {
  Footpaths(this.offset, this.target, this.metres, this.grid);

  final Int32List offset;
  final Int32List target;
  final Float32List metres;
  final StopGrid grid;

  int degree(int stop) => offset[stop + 1] - offset[stop];

  static Footpaths build(
    TransitIndex ix, {
    double radius = footpathRadiusMetres,
    StopClusters? clusters,
  }) {
    final grid = StopGrid(ix, cellMetres: math.max(200, radius));
    final edges = List<List<(int, double)>>.generate(ix.stopCount, (_) => []);
    for (var s = 0; s < ix.stopCount; s++) {
      for (final (t, d) in grid.near(ix.stopLat[s], ix.stopLon[s], radius)) {
        if (t != s) edges[s].add((t, d));
      }
    }
    // Transfers inside a display cluster must be transitively consistent: the
    // radius alone can leave two ends of a long cluster unconnected.
    final cl = clusters ?? StopClusters.build(ix);
    for (final group in cl.members) {
      for (final a in group) {
        for (final b in group) {
          if (a == b) continue;
          if (edges[a].any((e) => e.$1 == b)) continue;
          edges[a].add((
            b,
            haversineMetres(ix.stopLat[a], ix.stopLon[a], ix.stopLat[b],
                ix.stopLon[b]),
          ));
        }
      }
    }
    final offset = Int32List(ix.stopCount + 1);
    var total = 0;
    for (var s = 0; s < ix.stopCount; s++) {
      offset[s] = total;
      total += edges[s].length;
    }
    offset[ix.stopCount] = total;
    final target = Int32List(total);
    final metres = Float32List(total);
    for (var s = 0; s < ix.stopCount; s++) {
      final list = edges[s]..sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < list.length; i++) {
        target[offset[s] + i] = list[i].$1;
        metres[offset[s] + i] = list[i].$2;
      }
    }
    return Footpaths(offset, target, metres, grid);
  }
}
