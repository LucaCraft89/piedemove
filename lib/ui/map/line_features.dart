/// Line styling and the focus-mode feature builders (§9.4, §9.6, §9.9, §9.10).
///
/// The ambient network itself is a pre-built asset; this file only styles it
/// and builds the much smaller collections drawn when something is selected.
library;

import 'package:flutter/material.dart';

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/ambient.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/pattern_snap.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/theme/tokens.dart';

/// Tier zoom floors (§9.4): trams and rail always, frequent buses from z12,
/// the rest from z14.
const tier1MinZoom = 12.0, tier2MinZoom = 14.0;

String hexOf(Color c) => '#'
    '${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}'
    '${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}'
    '${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}';

/// A route's own shade inside its mode family: the hue walks a narrow band
/// around the mode colour, so a single-route line reads as "a bus", not as a
/// new mode.
Color shadeColor(Color mode, int shade) {
  final hsl = HSLColor.fromColor(mode);
  final step = (shade - (shadeCount - 1) / 2) * 9;
  return hsl
      .withHue((hsl.hue + step) % 360)
      .withLightness((hsl.lightness + (shade.isEven ? 0.04 : -0.04)).clamp(0.2, 0.8))
      .toColor();
}

/// Visible only where its tier's zoom floor is reached.
List<Object> get tierOpacity => [
      'case',
      ['==', ['get', 'tier'], 0], 1.0,
      ['==', ['get', 'tier'], 1], ['step', ['zoom'], 0.0, tier1MinZoom, 1.0],
      ['step', ['zoom'], 0.0, tier2MinZoom, 1.0],
    ];

/// `base(zoom) * min(1 + 0.4 * (n - 1), 3)` — the cap is the whole point.
List<Object> get ambientWidth => [
      '*',
      ['interpolate', ['linear'], ['zoom'], 11, 1.4, 14, 2.6, 17, 4.5],
      ['min', ['+', 1, ['*', 0.4, ['-', ['get', 'n'], 1]]], 3],
    ];

/// Mode colour when routes share the segment, the route's own shade when only
/// one route uses it.
List<Object> ambientColor(ModeColors modes) {
  final match = <Object>['match', ['concat', ['get', 'mode'], '-', ['to-string', ['get', 'shade']]]];
  for (final (key, color) in [
    ('bus', modes.bus),
    ('tram', modes.tram),
    ('metro', modes.metro),
    ('funicular', modes.funicular),
  ]) {
    for (var s = 0; s < shadeCount; s++) {
      match..add('$key-$s')..add(hexOf(shadeColor(color, s)));
    }
  }
  match.add(hexOf(modes.bus));
  return [
    'case',
    ['>', ['get', 'n'], 1], modeColor(modes),
    match,
  ];
}

List<Object> modeColor(ModeColors modes) => [
      'match',
      ['get', 'mode'],
      'tram', hexOf(modes.tram),
      'metro', hexOf(modes.metro),
      'funicular', hexOf(modes.funicular),
      hexOf(modes.bus),
    ];

Map<String, dynamic> _emptyCollection() =>
    {'type': 'FeatureCollection', 'features': <Map<String, dynamic>>[]};

Map<String, dynamic> _line(
  int id,
  List<List<double>> coords,
  Map<String, dynamic> props,
) =>
    {
      'type': 'Feature',
      'id': id,
      'geometry': {'type': 'LineString', 'coordinates': coords},
      'properties': props,
    };

List<List<double>> _slice(SnappedPattern p, int from, int to) => [
      for (var i = from; i <= to; i++) [p.vertexLon[i] / 1e6, p.vertexLat[i] / 1e6],
    ];

String _modeKey(int routeType) => switch (routeType) {
      RouteType.tram => 'tram',
      RouteType.metro => 'metro',
      RouteType.funicular => 'funicular',
      _ => 'bus',
    };

/// Focused route (§9.9): both directions at full width, nothing else.
Map<String, dynamic> routeFocusLines(
  TransitIndex ix,
  LineNetwork net,
  int route,
) {
  final out = _emptyCollection();
  var id = 0;
  for (var p = 0; p < ix.patternCount; p++) {
    if (ix.patternRoute[p] != route) continue;
    final geom = net[p];
    if (geom == null || geom.vertexCount < 2) continue;
    out['features'].add(_line(
      id++,
      _slice(geom, 0, geom.vertexCount - 1),
      {
        'mode': _modeKey(ix.routeTypes[route]),
        'routes': ix.routeShortNames[route],
        'n': 1,
        'tier': 0,
        'arrow': 1,
        'shade': shadeOf(ix.routeShortNames[route]),
        'ridden': 1,
      },
    ));
  }
  return out;
}

/// Stops of a focused route, termini larger (§9.9).
Map<String, dynamic> routeFocusStops(
  TransitIndex ix,
  int route,
) {
  final out = _emptyCollection();
  final seen = <int>{};
  for (var p = 0; p < ix.patternCount; p++) {
    if (ix.patternRoute[p] != route) continue;
    final len = ix.patternLength(p);
    for (var i = 0; i < len; i++) {
      final stop = ix.patternStopAt(p, i);
      final terminus = i == 0 || i == len - 1;
      if (!seen.add(stop) && !terminus) continue;
      out['features'].add({
        'type': 'Feature',
        'id': stop,
        'geometry': {
          'type': 'Point',
          'coordinates': [ix.stopLon[stop], ix.stopLat[stop]],
        },
        'properties': {
          'stop': stop,
          'name': cleanStopName(ix.stopNames[stop]),
          'mode': _modeKey(ix.routeTypes[route]),
          'big': terminus ? 1 : 0,
        },
      });
    }
  }
  return out;
}

/// Position of [stop] in pattern [p], searching forward from [after] so a loop
/// route's second pass is taken when it should be (lesson 1).
int patternPositionOf(TransitIndex ix, int p, int stop, {int after = 0}) {
  for (var i = after; i < ix.patternLength(p); i++) {
    if (ix.patternStopAt(p, i) == stop) return i;
  }
  return -1;
}

/// Focused journey (§9.9): the ridden slice thick, the rest of each pattern
/// thin context, in the leg's mode colour.
Map<String, dynamic> journeyFocusLines(
  TransitIndex ix,
  LineNetwork net,
  Journey journey,
) {
  final out = _emptyCollection();
  var id = 0;
  for (final leg in journey.legs) {
    if (leg.kind != LegKind.ride || leg.options.isEmpty) continue;
    final option = leg.options.first;
    final geom = net[option.pattern];
    if (geom == null || geom.vertexCount < 2) continue;
    final mode = _modeKey(option.routeType);
    final props = {
      'mode': mode,
      'routes': option.routeShortName,
      'n': 1,
      'tier': 0,
      'shade': shadeOf(option.routeShortName),
    };
    out['features'].add(_line(
      id++,
      _slice(geom, 0, geom.vertexCount - 1),
      {...props, 'arrow': 0, 'ridden': 0},
    ));

    final from = patternPositionOf(ix, option.pattern, leg.fromStop);
    final to = from < 0
        ? -1
        : patternPositionOf(ix, option.pattern, leg.toStop, after: from + 1);
    if (from < 0 || to < 0) continue;
    // Slice by the stored stop vertex index, never by nearest-vertex search.
    out['features'].add(_line(
      id++,
      _slice(geom, geom.stopVertex[from], geom.stopVertex[to]),
      {...props, 'arrow': 1, 'ridden': 1},
    ));
  }
  return out;
}

/// Only the stops the journey touches; board and alight big (§9.9).
Map<String, dynamic> journeyFocusStops(TransitIndex ix, Journey journey) {
  final out = _emptyCollection();
  final seen = <int>{};
  void add(int stop, String mode, bool big) {
    if (stop < 0) return;
    if (!seen.add(stop) && !big) return;
    out['features'].add({
      'type': 'Feature',
      'id': stop,
      'geometry': {
        'type': 'Point',
        'coordinates': [ix.stopLon[stop], ix.stopLat[stop]],
      },
      'properties': {
        'stop': stop,
        'name': cleanStopName(ix.stopNames[stop]),
        'mode': mode,
        'big': big ? 1 : 0,
      },
    });
  }

  for (final leg in journey.legs) {
    if (leg.kind != LegKind.ride || leg.options.isEmpty) continue;
    final option = leg.options.first;
    final mode = _modeKey(option.routeType);
    add(leg.fromStop, mode, true);
    add(leg.toStop, mode, true);
    final from = patternPositionOf(ix, option.pattern, leg.fromStop);
    final to = from < 0
        ? -1
        : patternPositionOf(ix, option.pattern, leg.toStop, after: from + 1);
    for (var i = from + 1; i > 0 && i < to; i++) {
      add(ix.patternStopAt(option.pattern, i), mode, false);
    }
  }
  return out;
}

/// Walking legs (§9.10). [path] gives the walked geometry when it is known;
/// without one the leg is a straight line and stays marked approximate.
Map<String, dynamic> walkFeatures(
  TransitIndex ix,
  Journey journey, {
  required List<List<double>>? Function(int legIndex) path,
  double? originLat,
  double? originLon,
  double? destLat,
  double? destLon,
}) {
  final out = _emptyCollection();
  for (var i = 0; i < journey.legs.length; i++) {
    final leg = journey.legs[i];
    if (leg.kind != LegKind.walk || leg.walkMetres <= 0) continue;
    final a = leg.fromStop >= 0
        ? [ix.stopLon[leg.fromStop], ix.stopLat[leg.fromStop]]
        : (originLon == null || originLat == null ? null : [originLon, originLat]);
    final b = leg.toStop >= 0
        ? [ix.stopLon[leg.toStop], ix.stopLat[leg.toStop]]
        : (destLon == null || destLat == null ? null : [destLon, destLat]);
    if (a == null || b == null) continue;
    final walked = path(i);
    out['features'].add(_line(
      i,
      walked ?? [a, b],
      {
        'metres': leg.walkMetres.round(),
        'approx': walked == null ? 1 : 0,
      },
    ));
  }
  return out;
}

/// Colour by distance tier, differing from every mode colour (§9.10).
List<Object> walkColor(WalkColors walk) => [
      'case',
      ['<=', ['get', 'metres'], 150], hexOf(walk.short),
      ['<=', ['get', 'metres'], 400], hexOf(walk.medium),
      hexOf(walk.long),
    ];
