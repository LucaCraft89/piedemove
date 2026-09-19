/// Stops as GeoJSON, built once per index load.
///
/// Every stop is its own feature: two TRAPANI poles 150 m apart must stay
/// separate. Grouping is left to the source's own clustering below z15.
library;

import 'package:piedemove/data/transit_index.dart';

/// `mode` is the most distinctive mode served, for the dot colour;
/// `sort` lets journey stops win label collisions later (§10.1).
Map<String, dynamic> stopFeatureCollection(
  TransitIndex ix,
  List<Set<int>> stopModes,
) {
  final features = <Map<String, dynamic>>[];
  for (var s = 0; s < ix.stopCount; s++) {
    final modes = s < stopModes.length ? stopModes[s] : const <int>{};
    if (modes.isEmpty) continue; // stop no pattern serves: nothing to show
    features.add({
      'type': 'Feature',
      'id': s,
      'geometry': {
        'type': 'Point',
        'coordinates': [ix.stopLon[s], ix.stopLat[s]],
      },
      'properties': {
        'stop': s,
        'name': cleanStopName(ix.stopNames[s]),
        'mode': _modeKey(modes),
        // Per-mode flags, so a cluster can aggregate them with `max` and pick
        // the sprite split between the modes it actually contains.
        'b': modes.contains(RouteType.bus) ? 1 : 0,
        't': modes.contains(RouteType.tram) ? 1 : 0,
        'm': modes.contains(RouteType.metro) ? 1 : 0,
        'f': modes.contains(RouteType.funicular) ? 1 : 0,
      },
    });
  }
  return {'type': 'FeatureCollection', 'features': features};
}

String _modeKey(Set<int> modes) {
  if (modes.contains(RouteType.metro)) return 'metro';
  if (modes.contains(RouteType.funicular)) return 'funicular';
  if (modes.contains(RouteType.tram)) return 'tram';
  return 'bus';
}
