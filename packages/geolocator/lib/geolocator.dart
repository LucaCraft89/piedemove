/// The part of `package:geolocator` PiedeMove uses, on Android's own
/// `LocationManager` (GPS + network providers) with no Google Play Services:
/// the F-Droid build swaps this in with `dependency_overrides`, so the app's
/// code is the same on every branch. Native side: FossLocationPlugin.java.
library;

import 'dart:async';

import 'package:flutter/services.dart';

enum LocationPermission { denied, deniedForever, whileInUse, always, unableToDetermine }

enum LocationAccuracy { lowest, low, medium, high, best, bestForNavigation, reduced }

class Position {
  const Position({
    required this.longitude,
    required this.latitude,
    required this.timestamp,
    required this.accuracy,
    required this.altitude,
    required this.altitudeAccuracy,
    required this.heading,
    required this.headingAccuracy,
    required this.speed,
    required this.speedAccuracy,
    this.floor,
    this.isMocked = false,
  });

  factory Position.fromMap(Map<dynamic, dynamic> m) {
    double d(String k, [double fallback = 0]) =>
        (m[k] as num?)?.toDouble() ?? fallback;
    return Position(
      latitude: d('latitude'),
      longitude: d('longitude'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
          (m['timestamp'] as num?)?.toInt() ?? 0),
      accuracy: d('accuracy'),
      altitude: d('altitude'),
      altitudeAccuracy: d('altitude_accuracy'),
      heading: d('heading', -1),
      headingAccuracy: d('heading_accuracy'),
      speed: d('speed'),
      speedAccuracy: d('speed_accuracy'),
      isMocked: m['is_mocked'] == true,
    );
  }

  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double accuracy;
  final double altitude;
  final double altitudeAccuracy;
  final double heading;
  final double headingAccuracy;
  final double speed;
  final double speedAccuracy;
  final int? floor;
  final bool isMocked;

  @override
  String toString() => 'Latitude: $latitude, Longitude: $longitude';
}

class LocationSettings {
  const LocationSettings({
    this.accuracy = LocationAccuracy.best,
    this.distanceFilter = 0,
    this.timeLimit,
  });

  final LocationAccuracy accuracy;
  final int distanceFilter;
  final Duration? timeLimit;
}

class AndroidResource {
  const AndroidResource({required this.name, this.defType = 'drawable'});

  final String name;
  final String defType;
}

class ForegroundNotificationConfig {
  const ForegroundNotificationConfig({
    required this.notificationTitle,
    required this.notificationText,
    this.notificationChannelName = 'Background Location',
    this.notificationIcon =
        const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    this.enableWifiLock = false,
    this.enableWakeLock = false,
    this.setOngoing = false,
  });

  final String notificationTitle;
  final String notificationText;
  final String notificationChannelName;
  final AndroidResource notificationIcon;
  final bool enableWifiLock;
  final bool enableWakeLock;
  final bool setOngoing;
}

class AndroidSettings extends LocationSettings {
  const AndroidSettings({
    super.accuracy,
    super.distanceFilter,
    super.timeLimit,
    this.forceLocationManager = false,
    this.intervalDuration,
    this.foregroundNotificationConfig,
  });

  final bool forceLocationManager;
  final Duration? intervalDuration;
  final ForegroundNotificationConfig? foregroundNotificationConfig;
}

class Geolocator {
  static const _methods = MethodChannel('piedemove/foss_location');
  static const _updates = EventChannel('piedemove/foss_location/updates');

  static LocationPermission _permission(int? code) => switch (code) {
        0 => LocationPermission.denied,
        1 => LocationPermission.deniedForever,
        2 => LocationPermission.whileInUse,
        3 => LocationPermission.always,
        _ => LocationPermission.unableToDetermine,
      };

  static Future<LocationPermission> checkPermission() async =>
      _permission(await _methods.invokeMethod<int>('checkPermission'));

  static Future<LocationPermission> requestPermission() async =>
      _permission(await _methods.invokeMethod<int>('requestPermission'));

  static Future<bool> isLocationServiceEnabled() async =>
      await _methods.invokeMethod<bool>('isLocationServiceEnabled') ?? false;

  static Future<Position?> getLastKnownPosition(
      {bool forceAndroidLocationManager = false}) async {
    final m = await _methods.invokeMethod<Map<dynamic, dynamic>>('getLastKnownPosition');
    return m == null ? null : Position.fromMap(m);
  }

  static Future<bool> openAppSettings() async =>
      await _methods.invokeMethod<bool>('openAppSettings') ?? false;

  static Future<bool> openLocationSettings() async =>
      await _methods.invokeMethod<bool>('openLocationSettings') ?? false;

  /// One platform stream, shared: the map dot and the live trip both listen.
  static Stream<Position>? _shared;
  static int _foreground = 0;

  static Stream<Position> _platform() => _shared ??= _updates
      .receiveBroadcastStream()
      .map((e) => Position.fromMap(e as Map<dynamic, dynamic>))
      .asBroadcastStream(onCancel: (s) {
        s.cancel();
        _shared = null;
      });

  /// Fixes from GPS (network ones only while GPS is silent). With a
  /// [ForegroundNotificationConfig] a location foreground service keeps them
  /// coming with the screen off, for as long as this stream is listened to.
  static Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    final fg = locationSettings is AndroidSettings
        ? locationSettings.foregroundNotificationConfig
        : null;
    StreamSubscription<Position>? sub;
    late final StreamController<Position> out;
    out = StreamController<Position>(
      onListen: () {
        if (fg != null && _foreground++ == 0) {
          _methods.invokeMethod<void>('startForeground', {
            'title': fg.notificationTitle,
            'text': fg.notificationText,
            'channelName': fg.notificationChannelName,
            'iconName': fg.notificationIcon.name,
            'iconType': fg.notificationIcon.defType,
            'wakeLock': fg.enableWakeLock,
          }).catchError((Object _) {});
        }
        sub = _platform().listen(out.add,
            onError: out.addError, onDone: out.close);
      },
      onCancel: () async {
        await sub?.cancel();
        if (fg != null && --_foreground == 0) {
          await _methods
              .invokeMethod<void>('stopForeground')
              .catchError((Object _) {});
        }
      },
    );
    return out.stream;
  }
}
