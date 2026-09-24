/// Photon (Komoot) place search (§11.3).
///
/// Debounce and stale-request cancellation live in the caller; this holds the
/// query, the Piemonte bounding box, the location bias and the cache.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Piemonte, generous bounds: lon 6.6..9.3, lat 44.0..46.6.
/// Photon's fair-use policy asks callers to identify themselves.
const userAgent = 'PiedeMove/1.0 (+https://github.com/LucaCraft89/piedemove)';

const piemonteBbox = (west: 6.6, south: 44.0, east: 9.3, north: 46.6);

class Place {
  const Place({
    required this.name,
    required this.address,
    required this.lat,
    required this.lon,
  });

  final String name;

  /// Full street address (street, number, city) — never the district.
  final String address;
  final double lat;
  final double lon;

  /// A Photon GeoJSON feature. Returns null when it carries no point.
  static Place? fromFeature(Map<String, dynamic> feature) {
    final coords = (feature['geometry'] as Map?)?['coordinates'];
    if (coords is! List || coords.length < 2) return null;
    final p = (feature['properties'] as Map?) ?? const {};
    final street = p['street'] as String?;
    final number = p['housenumber'] as String?;
    final city = (p['city'] ?? p['county'] ?? p['state']) as String?;
    final line = [
      if (street != null) [street, ?number].join(' '),
      ?city,
    ].join(', ');
    final name = (p['name'] as String?) ??
        (street == null ? null : [street, ?number].join(' ')) ??
        city ??
        '?';
    return Place(
      name: name,
      address: line,
      lat: (coords[1] as num).toDouble(),
      lon: (coords[0] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() =>
      {'n': name, 'a': address, 'lat': lat, 'lon': lon};

  static Place fromJson(Map<String, dynamic> j) => Place(
        name: j['n'] as String? ?? '',
        address: j['a'] as String? ?? '',
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
      );
}

/// A place search that has not answered in this long fails (chip shown).
const photonTimeout = Duration(seconds: 8);

class PhotonClient {
  PhotonClient({http.Client? client, this.limit = 8})
      : _http = client ?? http.Client();

  final http.Client _http;
  final int limit;
  final _cache = <String, List<Place>>{};

  /// Throws on network or feed failure; the caller shows a chip and keeps the
  /// other result sections (see CLAUDE.md, "Isolate failures").
  Future<List<Place>> search(String query, {double? lat, double? lon}) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    // The bias changes the ranking: round it (~1 km) into the key so moving
    // across town refreshes results without defeating the cache.
    final key = lat == null || lon == null
        ? q.toLowerCase()
        : '${q.toLowerCase()}@${lat.toStringAsFixed(2)},${lon.toStringAsFixed(2)}';
    final hit = _cache[key];
    if (hit != null) return hit;

    final uri = Uri.https('photon.komoot.io', '/api', {
      'q': q,
      'limit': '$limit',
      // Photon speaks default/de/en/fr only; 'default' keeps the local names.
      'lang': 'default',
      'bbox': '${piemonteBbox.west},${piemonteBbox.south},'
          '${piemonteBbox.east},${piemonteBbox.north}',
      if (lat != null && lon != null) ...{'lat': '$lat', 'lon': '$lon'},
    });
    // Photon answers 403 without an identifying User-Agent (fair use).
    final res = await _http
        .get(uri, headers: const {'User-Agent': userAgent})
        .timeout(photonTimeout);
    if (res.statusCode != 200) {
      throw http.ClientException('photon ${res.statusCode}', uri);
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final places = [
      for (final f in (body['features'] as List? ?? const []))
        ?Place.fromFeature(f as Map<String, dynamic>),
    ];
    // ponytail: unbounded-ish cache, cleared wholesale; an LRU if it ever grows.
    if (_cache.length > 100) _cache.clear();
    _cache[key] = places;
    return places;
  }
}
