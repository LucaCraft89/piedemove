import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:piedemove/location/device_location.dart';

Position _p({double heading = -1, double speed = 0}) => Position(
      latitude: 45,
      longitude: 7,
      timestamp: DateTime(2026),
      accuracy: 10,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: heading,
      headingAccuracy: 0,
      speed: speed,
      speedAccuracy: 0,
    );

void main() {
  test('services off wins over any permission', () {
    expect(mapLocStatus(false, LocationPermission.always), LocStatus.servicesOff);
  });
  test('permission mapping', () {
    expect(mapLocStatus(true, LocationPermission.whileInUse), LocStatus.ok);
    expect(mapLocStatus(true, LocationPermission.always), LocStatus.ok);
    expect(mapLocStatus(true, LocationPermission.denied), LocStatus.denied);
    expect(mapLocStatus(true, LocationPermission.unableToDetermine), LocStatus.denied);
    expect(mapLocStatus(true, LocationPermission.deniedForever), LocStatus.deniedForever);
  });
  test('heading only while moving', () {
    expect(usableHeading(_p(heading: 90, speed: 0)), isNull);
    expect(usableHeading(_p(heading: -1, speed: 3)), isNull);
    expect(usableHeading(_p(heading: 90, speed: 3)), 90);
  });
}
