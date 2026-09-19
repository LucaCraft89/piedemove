import 'dart:math' as math;

const earthRadiusMetres = 6371000.0;

double haversineMetres(double lat1, double lon1, double lat2, double lon2) {
  const toRad = math.pi / 180;
  final dLat = (lat2 - lat1) * toRad;
  final dLon = (lon2 - lon1) * toRad;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * toRad) *
          math.cos(lat2 * toRad) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * earthRadiusMetres * math.asin(math.min(1, math.sqrt(a)));
}
