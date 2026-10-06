// The position dot's beam: compass on foot, GPS course in a vehicle, width
// from the sensor's own error.
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:piedemove/location/compass.dart';
import 'package:piedemove/ui/map/me_layer.dart';

Position _p({double heading = -1, double speed = 0}) => Position(
      latitude: 45.07,
      longitude: 7.66,
      timestamp: DateTime(2026, 10, 6),
      accuracy: 8,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: heading,
      headingAccuracy: 0,
      speed: speed,
      speedAccuracy: 0,
    );

void main() {
  test('standing or walking: the compass, wherever the GPS course says', () {
    final h = meHeading(_p(heading: 90, speed: 1.4), const DeviceHeading(10, 12));
    expect(h!.degrees, 10);
    expect(h.spread, meBeamMin, reason: 'a sure compass: the narrow beam');
  });

  test('in a vehicle: the GPS course beats a compass among metal', () {
    final h = meHeading(_p(heading: 90, speed: 9), const DeviceHeading(10, 12));
    expect(h!.degrees, 90);
  });

  test('an unsure compass widens the beam, up to a limit', () {
    expect(meHeading(_p(), const DeviceHeading(370, 30))!.spread, 60);
    expect(meHeading(_p(), const DeviceHeading(0, 90))!.spread, meBeamMax);
    expect(meHeading(_p(), const DeviceHeading(370, 30))!.degrees, 10);
  });

  test('no compass: the course while moving, else no beam', () {
    expect(meHeading(_p(heading: 45, speed: 1.4), null)!.degrees, 45);
    expect(meHeading(_p(heading: 45, speed: 0), null), isNull);
    expect(meHeading(null, null), isNull);
  });

  test('the beam image is the narrowest that covers the spread', () {
    expect(meBeamImageFor(30), 'pm-me-beam-30');
    expect(meBeamImageFor(31), 'pm-me-beam-45');
    expect(meBeamImageFor(60), 'pm-me-beam-60');
    expect(meBeamImageFor(500), 'pm-me-beam-100');
  });

  test('the dot feature carries the beam; none hides it', () {
    Map<String, dynamic> props(Map<String, dynamic> c) =>
        ((c['features'] as List).single as Map)['properties']
            as Map<String, dynamic>;
    final on = meFeatures(_p(), heading: (degrees: 200, spread: 45));
    expect(props(on)['heading'], 200);
    expect(props(on)['beam'], 'pm-me-beam-45');
    expect(props(meFeatures(_p()))['heading'], -1);
  });
}
