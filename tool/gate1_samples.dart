/// GATE 1 — static line-style samples from real data.
///
///     dart tool/gate1_samples.dart            # -> build/gate1/*.svg
///
/// Draws the merged ambient network (§9.4 rules: merge by OSM way identity,
/// width capped at 3x, arrows only where a segment is used in one direction)
/// at three spots, in the dark palette, so look and line style can be approved
/// before the ambient layer is built in the app.
///
/// ponytail: segments are not chained into long LineStrings, and the merge
/// lives here, not in lib/. Chaining only changes chevron spacing; the app-side
/// builder belongs to phase 6 (9.4), after this gate.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/line_merge.dart';
import 'package:piedemove/geo/lines_io.dart';

/// The three spots the gate asks for, each a 600 m box.
const spots = [
  ('corso-francia-dual', 'Corso Francia: two carriageways', 45.0760, 7.6540),
  ('regina-bus-tram', 'Corso Regina Margherita: bus + tram', 45.0790, 7.6800),
  ('cristalliera-plain', 'Via Cristalliera: plain street', 45.0700, 7.6330),
];

const boxMetres = 600.0;
const size = 1200.0;

// Dark palette, PmTokens.darkTokens.
const busColour = '#4ADE80';
const tramColour = '#FB923C';
const metroColour = '#F87171';
const funiColour = '#C084FC';
const basemap = '#12161B';
const casing = '#0A0D11';
const stopFill = '#E6EAF0';

String colourOfMode(int routeType) => switch (routeType) {
  RouteType.tram => tramColour,
  RouteType.metro => metroColour,
  RouteType.funicular => funiColour,
  _ => busColour,
};

Future<void> main(List<String> args) async {
  final ix = await readIndexFile('build/index.bin');
  final net = await readLinesFile('build/lines.bin');
  if (ix == null || net == null) {
    stderr.writeln('build/index.bin or build/lines.bin missing or stale');
    exit(1);
  }
  final out = Directory('build/gate1')..createSync(recursive: true);

  for (final (slug, title, lat, lon) in spots) {
    final segs = _mergeAround(ix, net, lat, lon);
    final svg = _svg(ix, segs, title, lat, lon);
    File('${out.path}/$slug.svg').writeAsStringSync(svg);
    final routes = {for (final s in segs) ...s.routes};
    final modes = {for (final s in segs) s.mode};
    stdout.writeln('$slug: ${segs.length} segments, '
        '${routes.length} routes ${routes.take(12).toList()..sort()}, '
        'modes $modes');
  }
  stdout.writeln('wrote ${out.path}/*.svg');
}

/// Merge by (mode, way, segment), never by proximity.
List<MergedSeg> _mergeAround(
  TransitIndex ix,
  LineNetwork net,
  double lat,
  double lon,
) {
  final dLat = boxMetres / 2 / 111320;
  final dLon = dLat / math.cos(lat * math.pi / 180);
  final merger = LineMerger();

  for (final p in net.patterns) {
    final mode = ix.routeTypeOfPattern(p.pattern);
    final name = ix.routeShortNameOfPattern(p.pattern);
    for (var i = 1; i < p.vertexCount; i++) {
      final aLat = p.vertexLat[i - 1] / 1e6, aLon = p.vertexLon[i - 1] / 1e6;
      final bLat = p.vertexLat[i] / 1e6, bLon = p.vertexLon[i] / 1e6;
      if (!_inBox(aLat, aLon, lat, lon, dLat, dLon) &&
          !_inBox(bLat, bLon, lat, lon, dLat, dLon)) {
        continue;
      }
      merger.add(
        mode: mode,
        route: name,
        way: p.vertexWay[i],
        aLat: aLat,
        aLon: aLon,
        bLat: bLat,
        bLon: bLon,
      );
    }
  }
  return merger.segments;
}

bool _inBox(
  double lat,
  double lon,
  double cLat,
  double cLon,
  double dLat,
  double dLon,
) =>
    (lat - cLat).abs() <= dLat && (lon - cLon).abs() <= dLon;

String _svg(
  TransitIndex ix,
  List<MergedSeg> segs,
  String title,
  double cLat,
  double cLon,
) {
  final dLat = boxMetres / 2 / 111320;
  final dLon = dLat / math.cos(cLat * math.pi / 180);
  double x(double lon) => (lon - (cLon - dLon)) / (2 * dLon) * size;
  double y(double lat) => (1 - (lat - (cLat - dLat)) / (2 * dLat)) * size;

  final b = StringBuffer()
    ..writeln('<svg xmlns="http://www.w3.org/2000/svg" width="${size.toInt()}" '
        'height="${size.toInt()}" viewBox="0 0 ${size.toInt()} ${size.toInt()}">')
    ..writeln('<rect width="100%" height="100%" fill="$basemap"/>')
    ..writeln('<defs>')
    ..writeln('<marker id="chev" viewBox="0 0 10 10" refX="5" refY="5" '
        'markerWidth="3.2" markerHeight="3.2" orient="auto">'
        '<path d="M2,2 L6,5 L2,8" fill="none" stroke="#0A0D11" '
        'stroke-width="2.2" stroke-linecap="round"/></marker>')
    ..writeln('</defs>');

  // Casings first, then the lines: one pass each, so no casing sits on a line.
  for (final pass in [0, 1]) {
    for (final seg in segs) {
      final w = mergedWidth(seg.routes.length);
      final colour = pass == 0 ? casing : colourOfMode(seg.mode);
      final width = pass == 0 ? w + 3 : w;
      // §9.5: a tram and a bus on the same street are separate OSM ways, so
      // they are offset by half a stroke instead of merged.
      // Chevrons only on a segment long enough to carry one: a marker per
      // short segment reads as a dashed line, not as direction.
      final px = math.sqrt(
        math.pow(x(seg.bLon) - x(seg.aLon), 2) +
            math.pow(y(seg.bLat) - y(seg.aLat), 2),
      );
      final marker = pass == 1 && seg.oneDirection && px > 45
          ? ' marker-end="url(#chev)"'
          : '';
      b.writeln('<line x1="${x(seg.aLon).toStringAsFixed(1)}" '
          'y1="${y(seg.aLat).toStringAsFixed(1)}" '
          'x2="${x(seg.bLon).toStringAsFixed(1)}" '
          'y2="${y(seg.bLat).toStringAsFixed(1)}" stroke="$colour" '
          'stroke-width="${width.toStringAsFixed(1)}" '
          'stroke-linecap="round"$marker/>');
    }
  }

  // Stop poles inside the box.
  for (var s = 0; s < ix.stopCount; s++) {
    if (ix.stopPatternOffset[s] == ix.stopPatternOffset[s + 1]) continue;
    final lat = ix.stopLat[s], lon = ix.stopLon[s];
    if (!_inBox(lat, lon, cLat, cLon, dLat, dLon)) continue;
    final modes = {for (final r in ix.routesAt(s)) ix.routeTypes[r]};
    final colour = colourOfMode(
      modes.contains(RouteType.metro)
          ? RouteType.metro
          : modes.contains(RouteType.tram)
              ? RouteType.tram
              : RouteType.bus,
    );
    b.writeln('<circle cx="${x(lon).toStringAsFixed(1)}" '
        'cy="${y(lat).toStringAsFixed(1)}" r="5" fill="$stopFill" '
        'stroke="$colour" stroke-width="3"/>');
  }

  b
    ..writeln('<rect x="0" y="0" width="${size.toInt()}" height="52" '
        'fill="#000" fill-opacity="0.55"/>')
    ..writeln('<text x="16" y="34" fill="#E6EAF0" font-size="22" '
        'font-family="Google Sans Flex, sans-serif">$title · '
        '${boxMetres.toInt()} m · dark palette</text>')
    ..writeln('</svg>');
  return b.toString();
}
