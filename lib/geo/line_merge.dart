/// Merging snapped patterns into the ambient network (§9.4/§9.5).
///
/// Merge by **shared OSM way identity**, same mode only — never by proximity
/// (lesson 4). Both directions of one way collapse into one segment; the
/// direction set is kept so §9.6 can draw an arrow only where a segment is
/// used in exactly one direction.
library;

import 'dart:math' as math;

class MergedSeg {
  MergedSeg(this.aLat, this.aLon, this.bLat, this.bLon, this.mode, this.way);
  final double aLat, aLon, bLat, bLon;
  final int mode;
  final int way;

  /// Route short names sharing this segment. Its size is the merge count `n`.
  final Set<String> routes = {};

  /// 0 = drawn direction, 1 = against it.
  final Set<int> dirs = {};

  bool get oneDirection => dirs.length == 1;
}

class LineMerger {
  final _merged = <String, MergedSeg>{};

  void add({
    required int mode,
    required String route,
    required int way,
    required double aLat,
    required double aLon,
    required double bLat,
    required double bLon,
  }) {
    if (way < 0) return; // chord: not part of the ambient network
    final forward = (aLat < bLat) || (aLat == bLat && aLon <= bLon);
    final key = '$mode/$way/'
        '${forward ? '$aLat,$aLon,$bLat,$bLon' : '$bLat,$bLon,$aLat,$aLon'}';
    final seg = _merged.putIfAbsent(
      key,
      () => forward
          ? MergedSeg(aLat, aLon, bLat, bLon, mode, way)
          : MergedSeg(bLat, bLon, aLat, aLon, mode, way),
    );
    seg.routes.add(route);
    seg.dirs.add(forward ? 0 : 1);
  }

  /// Tram over bus: a shared street draws both, tram on top.
  List<MergedSeg> get segments =>
      _merged.values.toList()..sort((a, b) => a.mode.compareTo(b.mode));
}

/// Stroke width for `n` merged routes, capped at 3x the single-line width.
double mergedWidth(int n, {double base = 4.0}) =>
    base * math.min(1 + 0.4 * (n - 1), 3.0);
