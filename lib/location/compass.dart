/// The way the phone points, for the position dot's beam (rider request:
/// "show pointing direction like Google Maps"). Native side: MainActivity's
/// `Compass` - the fused rotation-vector sensor, corrected to true north with
/// the device's own geomagnetic model. Nothing is stored or sent anywhere.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import 'package:piedemove/location/device_location.dart';

/// One compass reading: degrees clockwise from true north, and the sensor's
/// own estimate of its error in degrees (wider beam when unsure).
@immutable
class DeviceHeading {
  const DeviceHeading(this.degrees, this.accuracy);
  final double degrees;
  final double accuracy;
}

/// What the dot draws: where it points and how wide the beam is (degrees,
/// total opening).
typedef MeHeading = ({double degrees, double spread});

/// Above this speed (m/s, ~14 km/h) the rider is in a vehicle: the GPS course
/// is the way they travel, and a magnetometer inside a bus or tram reads the
/// metal around it, not north.
const meCourseSpeed = 4.0;

/// Beam openings, degrees. The beam is a hint, never narrower than this.
const meBeamMin = 30.0, meBeamMax = 100.0;

/// Pure: compass when it is the best guess, else the GPS course, else none.
MeHeading? meHeading(Position? p, DeviceHeading? compass) {
  final course = p == null ? null : usableHeading(p);
  if (course != null && p!.speed >= meCourseSpeed) {
    return (degrees: course, spread: meBeamMin);
  }
  if (compass != null) {
    return (
      degrees: compass.degrees % 360,
      spread: (compass.accuracy * 2).clamp(meBeamMin, meBeamMax).toDouble(),
    );
  }
  if (course != null) return (degrees: course, spread: 45.0);
  return null;
}

final compassProvider =
    StateNotifierProvider<CompassController, DeviceHeading?>(
        (ref) => CompassController());

/// Listens to the sensor only while the app is in the foreground. No sensor
/// (or no platform, in tests) leaves the state null: the dot falls back to
/// the GPS course.
class CompassController extends StateNotifier<DeviceHeading?>
    with WidgetsBindingObserver {
  CompassController() : super(null) {
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  static const _events = EventChannel('piedemove/heading');
  static const _cfg = MethodChannel('piedemove/heading_cfg');

  StreamSubscription<dynamic>? _sub;
  (double, double)? _declinationAt;

  void _listen() {
    if (_sub != null) return;
    try {
      _sub = _events.receiveBroadcastStream().listen(
        (e) {
          if (e is! Map) return;
          final deg = (e['deg'] as num?)?.toDouble();
          final acc = (e['acc'] as num?)?.toDouble();
          if (deg == null || !mounted) return;
          state = DeviceHeading(deg, acc ?? 45);
        },
        onError: (Object e) {
          debugPrint('pm: compass: $e');
          _stop();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('pm: compass unavailable: $e');
    }
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    if (mounted) state = null;
  }

  /// Magnetic -> true north depends on where the rider is: refreshed when
  /// they have moved ~50 km (or on the first fix). Turin is ~3° east.
  void updateLocation(Position p) {
    final at = _declinationAt;
    if (at != null &&
        (at.$1 - p.latitude).abs() < 0.5 &&
        (at.$2 - p.longitude).abs() < 0.5) {
      return;
    }
    _declinationAt = (p.latitude, p.longitude);
    _cfg.invokeMethod<bool>('location', {
      'lat': p.latitude,
      'lon': p.longitude,
      'alt': p.altitude,
    }).catchError((Object _) => false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _listen();
    } else if (state == AppLifecycleState.paused) {
      _stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
