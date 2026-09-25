/// OSM ways from `osmium cat -f opl` (after `osmium add-locations-to-ways`),
/// in the Overpass `out geom` JSON shape [parseOsmJson] reads.
///
/// The lines build fetches Overpass tiles on a desktop; a CI runner cannot rely
/// on Overpass, so it reads a Geofabrik extract through osmium instead and
/// hands the result to the same graph builder. Same data, same code path.
library;

/// Decodes OPL's `%hex%` escapes.
String _dec(String s) => s.contains('%')
    ? s.replaceAllMapped(RegExp(r'%([0-9a-fA-F]+)%'),
        (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
    : s;

/// Ways among [lines] whose tags pass [keep], with their node coordinates as
/// `geometry`. Ways missing a location for any node are skipped (a clipped
/// extract edge): the graph never gets a guessed vertex.
Map<String, dynamic> oplWaysToOverpassGeom(
  Iterable<String> lines,
  bool Function(Map<String, String> tags) keep,
) {
  final elements = <Map<String, dynamic>>[];
  for (final line in lines) {
    if (line.length < 2 || line[0] != 'w') continue;
    int? id;
    var tags = <String, String>{};
    List<Map<String, double>>? geometry;
    var complete = true;
    for (final f in line.split(' ')) {
      if (f.isEmpty) continue;
      final v = f.substring(1);
      switch (f[0]) {
        case 'w':
          id = int.tryParse(v);
        case 'T':
          tags = {
            for (final kv in v.split(','))
              if (kv.contains('='))
                _dec(kv.substring(0, kv.indexOf('='))):
                    _dec(kv.substring(kv.indexOf('=') + 1)),
          };
        case 'N':
          geometry = [];
          for (final ref in v.split(',')) {
            final x = ref.indexOf('x'), y = ref.indexOf('y');
            if (x < 0 || y < 0) {
              complete = false;
              break;
            }
            final lon = double.tryParse(ref.substring(x + 1, y));
            final lat = double.tryParse(ref.substring(y + 1));
            if (lon == null || lat == null) {
              complete = false;
              break;
            }
            geometry.add({'lat': lat, 'lon': lon});
          }
      }
    }
    if (id == null || geometry == null || !complete || geometry.length < 2) {
      continue;
    }
    if (!keep(tags)) continue;
    elements.add({'type': 'way', 'id': id, 'tags': tags, 'geometry': geometry});
  }
  return {'elements': elements};
}

/// What the Overpass tile query asks for: every `highway` way plus tram track.
bool isRoadOrTramWay(Map<String, String> t) =>
    t.containsKey('highway') || t['railway'] == 'tram';

/// What the Overpass rail query asks for: metro, light rail, funicular.
bool isRailWay(Map<String, String> t) => const {
      'subway',
      'light_rail',
      'funicular',
      'monorail',
    }.contains(t['railway']);
