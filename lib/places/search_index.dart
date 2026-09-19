/// Local search over the on-device index: stops, lines, and live vehicles.
///
/// Diacritic-insensitive, token-prefix matching. Everything here is pure, so
/// the search box keeps working with every feed down.
library;

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/distance.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';

const _accents = 'àáâãäåèéêëìíîïòóôõöùúûüçñ';
const _plain = 'aaaaaaeeeeiiiiooooouuuucn';

/// Lowercases and strips diacritics: `"Città"` -> `"citta"`.
String fold(String s) => String.fromCharCodes(
      s.toLowerCase().codeUnits.map((c) => _foldMap[c] ?? c),
    );

final _foldMap = {
  for (var i = 0; i < _accents.length; i++)
    _accents.codeUnitAt(i): _plain.codeUnitAt(i),
};

final _splitter = RegExp(r'[^a-z0-9]+');

List<String> _tokens(String s) =>
    fold(s).split(_splitter).where((t) => t.isNotEmpty).toList();

/// True when every query token prefixes some token of [text] (or the whole).
bool matchesQuery(String text, String query) {
  final qs = _tokens(query);
  if (qs.isEmpty) return false;
  final ts = _tokens(text);
  final joined = ts.join();
  return qs.every(
    (q) => ts.any((t) => t.startsWith(q)) || joined.startsWith(q),
  );
}

/// Stop indices matching [query], nearest first when a position is known.
List<int> searchStops(
  TransitIndex ix,
  String query, {
  double? lat,
  double? lon,
  int limit = 12,
}) {
  final hits = <(int, double)>[];
  for (var s = 0; s < ix.stopCount; s++) {
    // Stops no line serves are noise in a result list.
    if (ix.stopPatternOffset[s] == ix.stopPatternOffset[s + 1]) continue;
    final name = cleanStopName(ix.stopNames[s]);
    if (!matchesQuery(name, query) && !matchesQuery(ix.stopCodes[s], query)) continue;
    final d = (lat == null || lon == null)
        ? 0.0
        : haversineMetres(lat, lon, ix.stopLat[s], ix.stopLon[s]);
    hits.add((s, d));
  }
  hits.sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final h in hits.take(limit)) h.$1];
}

/// Route indices matching [query], by number or name.
List<int> searchRoutes(TransitIndex ix, String query, {int limit = 12}) {
  final q = fold(query.trim());
  final hits = <int>[];
  for (var r = 0; r < ix.routeCount; r++) {
    final short = fold(ix.routeShortNames[r]);
    if (short.startsWith(q) ||
        matchesQuery(ix.routeLongNames[r], query) ||
        matchesQuery(ix.routeShortNames[r], query)) {
      hits.add(r);
    }
  }
  hits.sort((a, b) {
    final sa = fold(ix.routeShortNames[a]), sb = fold(ix.routeShortNames[b]);
    final exact = (sb == q ? 1 : 0) - (sa == q ? 1 : 0);
    if (exact != 0) return exact;
    final na = int.tryParse(sa), nb = int.tryParse(sb);
    if (na != null && nb != null) return na.compareTo(nb);
    return sa.compareTo(sb);
  });
  return hits.take(limit).toList();
}

/// Live vehicles matching a fleet id or label.
List<RtVehicle> searchVehicles(
  Iterable<RtVehicle> vehicles,
  String query, {
  int limit = 8,
}) {
  final q = fold(query.trim());
  if (q.isEmpty) return const [];
  final hits = [
    for (final v in vehicles)
      if (fold(v.id).contains(q) || fold(v.label ?? '').contains(q)) v,
  ];
  hits.sort((a, b) => a.id.compareTo(b.id));
  return hits.take(limit).toList();
}
