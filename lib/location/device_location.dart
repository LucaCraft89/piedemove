/// Device location. Nothing is stored and nothing leaves the phone: the
/// position only draws the dot, centres the map and seeds "from my location".
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// Last known position, refreshed on demand. Null while unknown or denied.
final myPositionProvider = StateProvider<Position?>((_) => null);

/// Asks for permission if needed, then answers the current position.
/// Returns null when the user refuses or the fix times out — every caller
/// must keep working without it.
Future<Position?> locateMe() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
      ),
    );
    return position;
  } catch (_) {
    return Geolocator.getLastKnownPosition().catchError((_) => null);
  }
}
