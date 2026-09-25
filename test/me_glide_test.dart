// The position dot glides between fixes instead of jumping once a second.
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:piedemove/ui/map/me_layer.dart';

void main() {
  test('glide steps are even and end on the fix', () {
    final pts = meGlidePoints(45.0, 7.6, 45.0006, 7.6012);
    expect(pts, hasLength(meGlideSteps));
    expect(pts.last, (45.0006, 7.6012));
    expect(pts.first.$1, closeTo(45.0001, 1e-9));
    expect(pts.first.$2, closeTo(7.6002, 1e-9));
  });

  test('a glide step draws the fix elsewhere, same accuracy', () {
    final p = Position(
      latitude: 45.0006,
      longitude: 7.6012,
      timestamp: DateTime(2026, 9, 25),
      accuracy: 12,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
    final at = meFeatures(p, at: (45.0003, 7.6006));
    final plain = meFeatures(p);
    Map<String, dynamic> f(Map<String, dynamic> c) =>
        (c['features'] as List).single as Map<String, dynamic>;
    expect(f(at)['geometry']['coordinates'], [7.6006, 45.0003]);
    expect(f(plain)['geometry']['coordinates'], [7.6012, 45.0006]);
    expect(f(at)['properties'], f(plain)['properties']);
  });
}
