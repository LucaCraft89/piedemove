/// Our own OpenFreeMap (OpenMapTiles schema) vector style, one per variant.
///
/// Nothing here is a third-party style: the JSON is built from the named
/// [MapPalette] tokens, so a colour is tuned in one place. The style is a
/// bundled string (works offline); only tiles and glyphs come from the network.
/// Attribution rides on the vector source and shows in the map's (i) button.
library;

import 'dart:convert';

import 'package:piedemove/settings/settings.dart';

/// One road class: fill and casing colour, widths at z10/z14/z18.
class RoadStyle {
  const RoadStyle(this.fill, this.casing, this.w10, this.w14, this.w18);
  final String fill, casing;
  final double w10, w14, w18;
}

/// Colour tokens of one basemap variant. Overlays (lines, walk, stops, dot)
/// sit on `bg`; `halo`/`text` also serve the overlay labels.
class MapPalette {
  const MapPalette({
    required this.name,
    required this.dark,
    required this.bg,
    required this.water,
    required this.park,
    required this.landuse,
    required this.building,
    required this.buildingLine,
    required this.motorway,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.minor,
    required this.path,
    required this.rail,
    required this.text,
    required this.halo,
    required this.waterText,
  });

  final String name;
  final bool dark;
  final String bg, water, park, landuse, building, buildingLine;
  final RoadStyle motorway, primary, secondary, tertiary, minor;
  final String path, rail;
  final String text, halo, waterText;
}

const _light = MapPalette(
  name: 'light',
  dark: false,
  bg: '#f1efe9',
  water: '#c9dbe8',
  park: '#dfe8d3',
  landuse: '#e9e6de',
  building: '#e2ded5',
  buildingLine: '#d3cec3',
  motorway: RoadStyle('#ffffff', '#a9a49a', 2.5, 5, 14),
  primary: RoadStyle('#ffffff', '#b4afa5', 1.6, 4, 12),
  secondary: RoadStyle('#ffffff', '#c0bbb1', 1.2, 3.2, 10),
  tertiary: RoadStyle('#ffffff', '#cbc7bd', 0.8, 2.6, 8),
  minor: RoadStyle('#fbfaf7', '#d5d1c7', 0.4, 1.8, 6),
  path: '#c2bdb2',
  rail: '#b9b4a9',
  text: '#3b3b3b',
  halo: '#ffffff',
  waterText: '#5a7a90',
);

const _dark = MapPalette(
  name: 'dark',
  dark: true,
  bg: '#181b20',
  water: '#0f2433',
  park: '#1c2a22',
  landuse: '#1d2025',
  building: '#22262c',
  buildingLine: '#2b3037',
  motorway: RoadStyle('#6a7484', '#0d0f12', 2.5, 5, 14),
  primary: RoadStyle('#5c6574', '#0d0f12', 1.6, 4, 12),
  secondary: RoadStyle('#505867', '#0d0f12', 1.2, 3.2, 10),
  tertiary: RoadStyle('#454c59', '#0d0f12', 0.8, 2.6, 8),
  minor: RoadStyle('#3b414d', '#15181c', 0.4, 1.8, 6),
  path: '#3a404b',
  rail: '#454c58',
  text: '#c9ced6',
  halo: '#181b20',
  waterText: '#7fa3bd',
);

const _colour = MapPalette(
  name: 'colour',
  dark: false,
  bg: '#f4f0e6',
  water: '#a8d3ee',
  park: '#cfe6b3',
  landuse: '#ece6d6',
  building: '#e4dccb',
  buildingLine: '#d6cdb9',
  motorway: RoadStyle('#f6c4a0', '#c98a5e', 2.5, 5, 14),
  primary: RoadStyle('#f8e2a6', '#cdb26a', 1.6, 4, 12),
  secondary: RoadStyle('#fdf0c4', '#d6c48a', 1.2, 3.2, 10),
  tertiary: RoadStyle('#ffffff', '#c4bba6', 0.8, 2.6, 8),
  minor: RoadStyle('#fffdf8', '#cdc4ae', 0.4, 1.8, 6),
  path: '#bfb59c',
  rail: '#a9a08c',
  text: '#3a3630',
  halo: '#ffffff',
  waterText: '#3d7396',
);

const _contrast = MapPalette(
  name: 'contrast',
  dark: false,
  bg: '#ffffff',
  water: '#cfe3f3',
  park: '#e3f0d8',
  landuse: '#f4f4f4',
  building: '#e6e6e6',
  buildingLine: '#8a8a8a',
  motorway: RoadStyle('#d9d9d9', '#000000', 2.5, 5, 14),
  primary: RoadStyle('#e4e4e4', '#1a1a1a', 1.6, 4, 12),
  secondary: RoadStyle('#eeeeee', '#333333', 1.2, 3.2, 10),
  tertiary: RoadStyle('#f6f6f6', '#4a4a4a', 0.8, 2.6, 8),
  minor: RoadStyle('#ffffff', '#666666', 0.4, 1.8, 6),
  path: '#777777',
  rail: '#555555',
  text: '#000000',
  halo: '#ffffff',
  waterText: '#12456b',
);

/// The palette for a setting; `auto` follows the app theme.
MapPalette mapPalette(MapStyleKind kind, {required bool appDark}) => switch (kind) {
      MapStyleKind.auto => appDark ? _dark : _light,
      MapStyleKind.light => _light,
      MapStyleKind.dark => _dark,
      MapStyleKind.colour => _colour,
      MapStyleKind.highContrast => _contrast,
    };

const _tiles = 'https://tiles.openfreemap.org/planet';
const _glyphs = 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf';
const _font = ['Noto Sans Regular'];
const _fontBold = ['Noto Sans Bold'];

List _w(double a, double b, double c) => [
      'interpolate', ['exponential', 1.4], ['zoom'],
      10, a, 14, b, 18, c,
    ];

List _cls(List<String> classes) => [
      'match', ['get', 'class'], classes, true, false,
    ];

Map<String, dynamic> _road(String id, RoadStyle r, List<String> classes,
    {int minzoom = 5, bool casing = false, double extra = 0}) {
  final w = _w(r.w10 + (casing ? extra : 0), r.w14 + (casing ? extra : 0),
      r.w18 + (casing ? extra * 2 : 0));
  return {
    'id': id,
    'type': 'line',
    'source': 'openmaptiles',
    'source-layer': 'transportation',
    'minzoom': minzoom,
    'filter': _cls(classes),
    'layout': {'line-cap': 'round', 'line-join': 'round'},
    'paint': {
      'line-color': casing ? r.casing : r.fill,
      'line-width': w,
    },
  };
}

/// Full style JSON for [p], as a string MapLibre loads directly.
String buildBasemapStyle(MapPalette p) {
  Map<String, dynamic> fill(String id, String layer, String colour,
          {List? filter, int minzoom = 0}) =>
      {
        'id': id,
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': layer,
        'minzoom': minzoom,
        'filter': ?filter,
        'paint': {'fill-color': colour},
      };
  Map<String, dynamic> label(String id, String layer, List filter, double size,
          {bool bold = false, String placement = 'point', int minzoom = 0}) =>
      {
        'id': id,
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': layer,
        'minzoom': minzoom,
        'filter': filter,
        'layout': {
          'text-field': ['coalesce', ['get', 'name:latin'], ['get', 'name']],
          'text-font': bold ? _fontBold : _font,
          'text-size': size,
          'symbol-placement': placement,
          'text-max-width': 8,
        },
        'paint': {
          'text-color': layer == 'water_name' ? p.waterText : p.text,
          'text-halo-color': p.halo,
          'text-halo-width': 1.6,
        },
      };

  const major = ['motorway', 'trunk'];
  final roads = <(String, RoadStyle, List<String>, int)>[
    ('minor', p.minor, ['minor', 'service', 'track', 'raceway'], 13),
    ('tertiary', p.tertiary, ['tertiary'], 11),
    ('secondary', p.secondary, ['secondary'], 9),
    ('primary', p.primary, ['primary'], 7),
    ('motorway', p.motorway, major, 5),
  ];

  final layers = <Map<String, dynamic>>[
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': p.bg},
    },
    fill('landuse', 'landuse', p.landuse,
        filter: _cls(['residential', 'commercial', 'industrial', 'retail'])),
    fill('landcover', 'landcover', p.park,
        filter: _cls(['wood', 'grass', 'farmland'])),
    fill('park', 'park', p.park),
    fill('water', 'water', p.water),
    {
      'id': 'waterway',
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': 'waterway',
      'paint': {'line-color': p.water, 'line-width': _w(0.5, 1.5, 4)},
    },
    {
      ...fill('building', 'building', p.building, minzoom: 14),
      'paint': {
        'fill-color': p.building,
        'fill-outline-color': p.buildingLine,
      },
    },
    {
      'id': 'path',
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': 'transportation',
      'minzoom': 14,
      'filter': _cls(['path', 'pedestrian']),
      'paint': {
        'line-color': p.path,
        'line-width': _w(0.3, 0.8, 2),
        'line-dasharray': [2, 2],
      },
    },
    {
      'id': 'rail',
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': 'transportation',
      'minzoom': 11,
      'filter': _cls(['rail']),
      'paint': {'line-color': p.rail, 'line-width': _w(0.4, 0.9, 2)},
    },
    // Casings for every class first, then fills, so a junction of a major and
    // a minor road reads as one crossing, not a stack of outlines.
    for (final r in roads)
      _road('${r.$1}-casing', r.$2, r.$3, minzoom: r.$4, casing: true, extra: 1.2),
    for (final r in roads) _road('${r.$1}-fill', r.$2, r.$3, minzoom: r.$4),
    {
      'id': 'boundary',
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': 'boundary',
      'filter': ['<=', ['get', 'admin_level'], 6],
      'paint': {
        'line-color': p.path,
        'line-width': 0.8,
        'line-dasharray': [3, 2],
      },
    },
    label('water-label', 'water_name', ['has', 'name'], 11, minzoom: 12),
    label('road-label', 'transportation_name',
        _cls(['motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'minor']), 11,
        placement: 'line', minzoom: 13),
    label('place-suburb', 'place', _cls(['suburb', 'neighbourhood', 'quarter']), 11,
        minzoom: 12),
    label('place-town', 'place', _cls(['village', 'town']), 12, bold: true),
    label('place-city', 'place', _cls(['city']), 15, bold: true),
  ];

  return jsonEncode({
    'version': 8,
    'name': 'piedemove-${p.name}',
    'glyphs': _glyphs,
    'sources': {
      'openmaptiles': {
        'type': 'vector',
        'url': _tiles,
        'attribution':
            '<a href="https://openfreemap.org">OpenFreeMap</a> '
                '<a href="https://www.openmaptiles.org/">© OpenMapTiles</a> '
                'Data from <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      },
    },
    'layers': layers,
  });
}
