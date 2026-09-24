/// Device location, single owner (FIX_MASTER phase 4). Nothing is stored and
/// nothing leaves the phone: the position draws the dot, centres the map,
/// seeds "from my location" and (phase 6) drives live progress.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

enum LocStatus { unknown, ok, denied, deniedForever, servicesOff }

/// Pure: services + permission -> what the UI must say and do.
LocStatus mapLocStatus(bool servicesOn, LocationPermission p) {
  if (!servicesOn) return LocStatus.servicesOff;
  return switch (p) {
    LocationPermission.always || LocationPermission.whileInUse => LocStatus.ok,
    LocationPermission.deniedForever => LocStatus.deniedForever,
    _ => LocStatus.denied,
  };
}

/// GPS course is only meaningful while moving; -1 = no heading.
double? usableHeading(Position p) =>
    p.heading >= 0 && p.speed > 0.7 ? p.heading : null;

class LocState {
  const LocState({this.status = LocStatus.unknown, this.position});
  final LocStatus status;
  final Position? position;
}

/// The one owner of permission, last-known fix and the ~1 Hz stream.
/// Phase 6 reads [locationProvider] (or [myPositionProvider]) — it never opens
/// its own stream for the dot.
final locationProvider =
    StateNotifierProvider<LocationController, LocState>((ref) {
  final c = LocationController();
  ref.onDispose(c.dispose);
  return c;
});

/// Last known position, null while unknown or denied.
final myPositionProvider =
    Provider<Position?>((ref) => ref.watch(locationProvider).position);

class LocationController extends StateNotifier<LocState>
    with WidgetsBindingObserver {
  LocationController() : super(const LocState()) {
    WidgetsBinding.instance.addObserver(this);
  }

  StreamSubscription<Position>? _sub;
  bool _foreground = true;

  /// Checks services + permission; [ask] shows the system prompt if needed.
  /// Never throws. Starts the stream when allowed.
  Future<void> start({bool ask = true}) async {
    try {
      final on = await Geolocator.isLocationServiceEnabled();
      var perm = await Geolocator.checkPermission();
      if (on && ask && perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      final status = mapLocStatus(on, perm);
      state = LocState(status: status, position: state.position);
      if (status != LocStatus.ok) return _stop();
      final last = await Geolocator.getLastKnownPosition().catchError((_) => null);
      if (last != null && state.position == null) _set(last);
      if (_foreground) _listen();
    } catch (e) {
      debugPrint('pm: location start failed: $e');
    }
  }

  /// Chip / button: fix whatever is fixable, else open the right system page.
  Future<void> activate() async {
    await start();
    switch (state.status) {
      case LocStatus.servicesOff:
        await Geolocator.openLocationSettings();
      case LocStatus.denied || LocStatus.deniedForever:
        await Geolocator.openAppSettings();
      default:
    }
  }

  void _set(Position p) => state = LocState(status: LocStatus.ok, position: p);

  void _listen() {
    if (_sub != null) return;
    try {
      _sub = Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          intervalDuration: const Duration(seconds: 1),
        ),
      ).listen(_set, onError: (Object e) => debugPrint('pm: stream: $e'));
    } catch (e) {
      debugPrint('pm: location stream unavailable: $e');
    }
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      // Re-check: the user may have come back from system settings.
      unawaited(start(ask: false));
    } else {
      _stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    super.dispose();
  }
}
