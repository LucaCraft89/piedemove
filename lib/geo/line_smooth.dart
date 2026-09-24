/// Geometry clean-up for the ambient network: spur removal on snapped patterns
/// and bounded curve smoothing on merged chains. General rules over shape
/// only, nothing keyed to a line or a place.
///
/// Gap safety: chain end points never move (so chains still meet at their
/// shared joints) and every smoothing step stays within a stated deviation of
/// the input polyline.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// A vertex that turns back on itself by more than this, with a short leg on
/// either side, is a spur (an out-and-back stub or routing jitter at a node).
const spurDegrees = 150.0;

const chainSpikeMaxLegMetres = 15.0;

/// Spike removal on merged chains uses a tighter leg limit than on patterns.

const spurMaxLegMetres = 40.0;

/// Consecutive vertices closer than this are one vertex.
const dedupeMetres = 0.5;

/// A vertex this close to the chord of its neighbours is dropped.
const collinearMetres = 0.3;

/// Corner cutting: turns below [smoothMinTurnDegrees] stay as they are; a cut
/// moves the line by at most [smoothMaxDeviationMetres] per pass.
const smoothMinTurnDegrees = 6.0;
const smoothMaxDeviationMetres = 2.5;
const smoothPasses = 2;

/// A closed chain whose way back stays within this of its way out is one stub
/// drawn twice (a turnaround): keep the way out only.
const retraceMetres = 1.5;

/// Upper bound of what the whole clean-up can move a line: used by the gap
/// detector as its match tolerance.
const smoothTotalDeviationMetres = smoothMaxDeviationMetres * smoothPasses;

const _mLat = 111320.0, _mLon = 111320.0 * 0.707; // cos(45 deg), Turin

/// Indices of the vertices left after dropping spurs. First and last stay.
List<int> spurFreeIndices(Int32List lat, Int32List lon) {
  final n = lat.length;
  double x(int i) => lon[i] / 1e6 * _mLon;
  double y(int i) => lat[i] / 1e6 * _mLat;
  double dist(int a, int b) =>
      math.sqrt(math.pow(x(a) - x(b), 2) + math.pow(y(a) - y(b), 2));
  final out = <int>[];
  for (var v = 0; v < n; v++) {
    while (out.length >= 2) {
      final a = out[out.length - 2], t = out.last;
      final l1 = dist(a, t), l2 = dist(t, v);
      if (l1 < dedupeMetres || l2 < dedupeMetres) break;
      final c = ((x(t) - x(a)) * (x(v) - x(t)) + (y(t) - y(a)) * (y(v) - y(t))) /
          (l1 * l2);
      final turn = math.acos(c.clamp(-1.0, 1.0)) * 180 / math.pi;
      if (turn > spurDegrees && math.min(l1, l2) <= spurMaxLegMetres) {
        out.removeLast();
      } else {
        break;
      }
    }
    // A return that lands on the vertex before the tip is the same vertex.
    if (out.isNotEmpty && v != n - 1 && dist(out.last, v) < dedupeMetres) continue;
    if (out.isNotEmpty && v == n - 1 && dist(out.last, v) < dedupeMetres && out.length > 1) {
      out.removeLast();
    }
    out.add(v);
  }
  return out;
}

/// Key of a joint coordinate (microdegrees), for the [pinned] sets below.
int jointKey(double lat, double lon) =>
    ((lat * 1e6).round() << 25) ^ (lon * 1e6).round();

/// Removes spikes from a merged chain: an interior, unpinned vertex that turns
/// back by more than [spurDegrees] with both legs at most [spurMaxLegMetres]
/// is a stub tip left by two patterns meeting at a node. Flat lat,lon.
List<double> dropSpikes(List<double> flat, {Set<int> pinned = const {}}) {
  final p = <(double, double)>[
    for (var i = 0; i + 1 < flat.length; i += 2)
      (flat[i + 1] * _mLon, flat[i] * _mLat)
  ];
  final out = <(double, double)>[p.first];
  for (var i = 1; i < p.length; i++) {
    var v = p[i];
    while (out.length >= 2) {
      final a = out[out.length - 2], t = out.last;
      final l1 = _d(a, t), l2 = _d(t, v);
      if (l1 < dedupeMetres || l2 < dedupeMetres || l1 > chainSpikeMaxLegMetres ||
          l2 > chainSpikeMaxLegMetres ||
          pinned.contains(jointKey(t.$2 / _mLat, t.$1 / _mLon))) {
        break;
      }
      final c = ((t.$1 - a.$1) * (v.$1 - t.$1) + (t.$2 - a.$2) * (v.$2 - t.$2)) /
          (l1 * l2);
      if (math.acos(c.clamp(-1.0, 1.0)) * 180 / math.pi <= spurDegrees) break;
      out.removeLast();
    }
    out.add(v);
  }
  return [
    for (final q in out) ...[q.$2 / _mLat, q.$1 / _mLon]
  ];
}

/// A chain shorter than this that dangles (one end touches no other chain) is
/// a stub tip left by stop snapping, not a line: it is dropped so the fold it
/// hung on can be cleaned up.
const microStubMetres = 6.0;

double polylineMetres(List<double> flat) {
  var m = 0.0;
  for (var i = 2; i + 1 < flat.length; i += 2) {
    m += math.sqrt(math.pow((flat[i] - flat[i - 2]) * _mLat, 2) +
        math.pow((flat[i + 1] - flat[i - 1]) * _mLon, 2));
  }
  return m;
}

/// A kink loop: a chain that crosses itself within this much line length.
const kinkLoopMetres = 80.0;

/// Cuts kink loops out of a chain: where segment j crosses an earlier segment
/// i within [kinkLoopMetres] of line, the vertices between are replaced by the
/// crossing point. Loops holding a pinned vertex stay (a chain meets there).
List<double> dropKinkLoops(List<double> flat, {Set<int> pinned = const {}}) {
  var p = <(double, double)>[
    for (var i = 0; i + 1 < flat.length; i += 2)
      (flat[i + 1] * _mLon, flat[i] * _mLat)
  ];
  var changed = true;
  while (changed) {
    changed = false;
    search:
    for (var i = 1; i < p.length; i++) {
      var along = 0.0;
      for (var j = i + 2; j < p.length; j++) {
        along += _d(p[j - 1], p[j - 2]);
        if (along > kinkLoopMetres) break;
        final x = _intersect(p[i - 1], p[i], p[j - 1], p[j]);
        if (x == null) continue;
        final pinnedInside = [for (var k = i; k < j; k++) p[k]].any(
            (q) => pinned.contains(jointKey(q.$2 / _mLat, q.$1 / _mLon)));
        if (pinnedInside) continue;
        p = [...p.sublist(0, i), x, ...p.sublist(j)];
        changed = true;
        break search;
      }
    }
  }
  return [
    for (final q in p) ...[q.$2 / _mLat, q.$1 / _mLon]
  ];
}

(double, double)? _intersect((double, double) a, (double, double) b,
    (double, double) c, (double, double) d) {
  final rx = b.$1 - a.$1, ry = b.$2 - a.$2, sx = d.$1 - c.$1, sy = d.$2 - c.$2;
  final den = rx * sy - ry * sx;
  if (den == 0) return null;
  final t = ((c.$1 - a.$1) * sy - (c.$2 - a.$2) * sx) / den;
  final u = ((c.$1 - a.$1) * ry - (c.$2 - a.$2) * rx) / den;
  if (t <= 0 || t >= 1 || u <= 0 || u >= 1) return null;
  return (a.$1 + t * rx, a.$2 + t * ry);
}

/// Smooths a flat `lat,lon,lat,lon...` polyline. Ends stay exact, and so does
/// every vertex whose [jointKey] is in [pinned]: another chain ends there, and
/// moving it would open a gap.
List<double> smoothPolyline(List<double> flat, {Set<int> pinned = const {}}) {
  var p = <(double, double)>[
    for (var i = 0; i + 1 < flat.length; i += 2)
      (flat[i + 1] * _mLon, flat[i] * _mLat)
  ];
  if (p.length < 3) return flat;
  bool pin((double, double) q) =>
      pinned.contains(jointKey(q.$2 / _mLat, q.$1 / _mLon));
  p = _dropRedundant(p, pin);
  for (var pass = 0; pass < smoothPasses; pass++) {
    p = _cutCorners(p, pin);
  }
  return [
    for (final q in p) ...[q.$2 / _mLat, q.$1 / _mLon]
  ];
}

double _d((double, double) a, (double, double) b) =>
    math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

/// A chain that leaves its start, turns at a tip and comes back over itself
/// to where it began is a stub drawn twice; keep the way out. Flat lat,lon.
List<double> collapseRetrace(List<double> flat) {
  final p = <(double, double)>[
    for (var i = 0; i + 1 < flat.length; i += 2)
      (flat[i + 1] * _mLon, flat[i] * _mLat)
  ];
  final q = _collapseRetrace(p);
  return q.length == p.length ? flat : flat.sublist(0, q.length * 2);
}

List<(double, double)> _collapseRetrace(List<(double, double)> p) {
  if (p.length < 3 || _d(p.first, p.last) > retraceMetres) return p;
  var tip = 1;
  for (var i = 2; i < p.length - 1; i++) {
    if (_d(p.first, p[i]) > _d(p.first, p[tip])) tip = i;
  }
  for (var i = tip + 1; i < p.length; i++) {
    var near = double.infinity;
    for (var j = 1; j <= tip; j++) {
      near = math.min(near, _distToSeg(p[i], p[j - 1], p[j]));
    }
    if (near > retraceMetres) return p;
  }
  return p.sublist(0, tip + 1);
}

double _distToSeg((double, double) q, (double, double) a, (double, double) b) {
  final dx = b.$1 - a.$1, dy = b.$2 - a.$2, l2 = dx * dx + dy * dy;
  final t = l2 == 0
      ? 0.0
      : (((q.$1 - a.$1) * dx + (q.$2 - a.$2) * dy) / l2).clamp(0.0, 1.0);
  return _d(q, (a.$1 + t * dx, a.$2 + t * dy));
}

/// Drops near-duplicate and collinear interior vertices.
List<(double, double)> _dropRedundant(
    List<(double, double)> p, bool Function((double, double)) pin) {
  final out = [p.first];
  for (var i = 1; i < p.length - 1; i++) {
    if (pin(p[i])) {
      out.add(p[i]);
      continue;
    }
    if (_d(out.last, p[i]) < dedupeMetres) continue;
    final a = out.last, b = p[i], c = p[i + 1];
    final ac = _d(a, c);
    if (ac > 0) {
      final cross = ((b.$1 - a.$1) * (c.$2 - a.$2) - (b.$2 - a.$2) * (c.$1 - a.$1)).abs() / ac;
      final dot = (b.$1 - a.$1) * (c.$1 - a.$1) + (b.$2 - a.$2) * (c.$2 - a.$2);
      if (cross < collinearMetres && dot > 0 && dot < ac * ac) continue;
    }
    out.add(b);
  }
  out.add(p.last);
  return out;
}

/// One Chaikin-style pass with a bounded cut: each corner V becomes two points
/// on its legs at distance d from V, d <= a quarter of the shorter leg and
/// small enough that the chord moves the line by at most the deviation cap.
List<(double, double)> _cutCorners(
    List<(double, double)> p, bool Function((double, double)) pin) {
  final out = [p.first];
  for (var i = 1; i < p.length - 1; i++) {
    final a = p[i - 1], v = p[i], b = p[i + 1];
    final l1 = _d(a, v), l2 = _d(v, b);
    if (l1 < 1e-6 || l2 < 1e-6) continue;
    final u1 = ((a.$1 - v.$1) / l1, (a.$2 - v.$2) / l1);
    final u2 = ((b.$1 - v.$1) / l2, (b.$2 - v.$2) / l2);
    final cosT = -(u1.$1 * u2.$1 + u1.$2 * u2.$2); // cos of the turn angle
    final turn = math.acos(cosT.clamp(-1.0, 1.0));
    final deg = turn * 180 / math.pi;
    // Too flat to bother, or a fold: cutting a fold's tip would eat the stub.
    if (pin(v) || deg < smoothMinTurnDegrees || deg > spurDegrees) {
      out.add(v);
      continue;
    }
    final d = math.min(math.min(l1, l2) / 4,
        smoothMaxDeviationMetres / math.max(math.sin(turn / 2), 1e-3));
    out
      ..add((v.$1 + u1.$1 * d, v.$2 + u1.$2 * d))
      ..add((v.$1 + u2.$1 * d, v.$2 + u2.$2 * d));
  }
  out.add(p.last);
  return out;
}
