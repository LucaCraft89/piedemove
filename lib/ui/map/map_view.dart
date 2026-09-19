/// The full-screen map and its stop layers.
///
/// Every layer is added in its own try/catch: a failed layer shows a status
/// chip, it never blanks the map (see CLAUDE.md, "Isolate failures").
library;

import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/places/saved.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/ui/theme/tokens.dart';

import 'stop_features.dart';
import 'vehicle_features.dart';

/// Turin, Porta Nuova.
const turin = LatLng(45.0625, 7.6785);
const _stopsSource = 'pm-stops';
const _vehiclesSource = 'pm-vehicles';

/// Vehicles appear from z12 (§10.1).
const vehicleMinZoom = 12.0;

/// Individual poles from z15; clusters below it.
const poleMinZoom = 15.0;

/// Non-null when a map layer failed to load; shown as a chip, never a blank map.
final mapStatusProvider = StateProvider<String?>((_) => null);

/// The "Veicoli" pill; off hides the layer without stopping the feed.
final vehiclesVisibleProvider = StateProvider<bool>((_) => true);

final mapControllerProvider = StateProvider<MapLibreMapController?>((_) => null);

typedef StopTap = void Function(int stopIndex);
typedef VehicleTap = void Function(String vehicleId);

class MapView extends ConsumerStatefulWidget {
  const MapView({super.key, this.onStopTap, this.onVehicleTap});

  final StopTap? onStopTap;
  final VehicleTap? onVehicleTap;

  @override
  ConsumerState<MapView> createState() => _MapViewState();
}

class _MapViewState extends ConsumerState<MapView> {
  MapLibreMapController? _controller;
  bool _styleReady = false;

  /// A style reload drops every source, and `setGeoJsonSource` does not fail
  /// loudly on Android when the source is gone — so track it here.
  bool _stopsAdded = false;
  bool _vehiclesAdded = false;

  /// Feature id -> vehicle id, in the order the collection was built.
  final _vehicleIds = <String>[];

  /// The place currently pinned by search, as last drawn.
  Place? _pinned;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The index and the style race each other: whichever lands second runs
    // this. Watching, not listening — a value already there fires no event.
    if (ref.watch(transitIndexProvider).valueOrNull != null && !_stopsAdded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _addStops());
    }

    final vehicles = ref.watch(realtimeProvider.select((s) => s.vehicles));
    final showVehicles = ref.watch(vehiclesVisibleProvider);
    if (_styleReady) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _updateVehicles(showVehicles ? vehicles.values : const []),
      );
    }

    final place = ref.watch(selectedPlaceProvider);
    if (_styleReady && !identical(place, _pinned)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updatePin(place));
    }

    return MapLibreMap(
      initialCameraPosition: const CameraPosition(target: turin, zoom: 13),
      styleString: dark
          ? 'https://tiles.openfreemap.org/styles/dark'
          : 'https://tiles.openfreemap.org/styles/positron',
      myLocationEnabled: true,
      myLocationRenderMode: MyLocationRenderMode.normal,
      trackCameraPosition: true,
      compassEnabled: false,
      attributionButtonPosition: AttributionButtonPosition.topRight,
      onMapCreated: (c) {
        _controller = c;
        c.onFeatureTapped.add(_onFeatureTapped);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => ref.read(mapControllerProvider.notifier).state = c,
        );
      },
      onStyleLoadedCallback: () {
        _styleReady = true;
        _stopsAdded = false;
        _vehiclesAdded = false;
        _pinned = null;
        _addStops();
      },
    );
  }

  void _onFeatureTapped(
    Point<double> point,
    LatLng coordinates,
    String id,
    String layerId,
    Annotation? annotation,
  ) {
    final controller = _controller;
    if (controller == null) return;
    if (layerId == 'pm-vehicle-touch') {
      final i = int.tryParse(id);
      if (i != null && i < _vehicleIds.length) {
        widget.onVehicleTap?.call(_vehicleIds[i]);
      }
      return;
    }
    if (layerId == 'pm-stop-clusters') {
      controller.animateCamera(CameraUpdate.newLatLngZoom(
        coordinates,
        (controller.cameraPosition?.zoom ?? 13) + 2,
      ));
      return;
    }
    final stop = int.tryParse(id);
    if (stop != null) widget.onStopTap?.call(stop);
  }

  Future<void> _addStops() async {
    final controller = _controller;
    final ix = ref.read(transitIndexProvider).valueOrNull;
    if (controller == null || ix == null || !_styleReady) return;

    final data = stopFeatureCollection(ix, ref.read(stopModesProvider));
    final tokens =
        Theme.of(context).brightness == Brightness.dark
            ? PmTokens.darkTokens
            : PmTokens.lightTokens;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final surface = Theme.of(context).colorScheme.surface;

    // Already on this style: replacing the data is enough.
    if (_stopsAdded) {
      try {
        await controller.setGeoJsonSource(_stopsSource, data);
      } catch (_) {
        _stopsAdded = false;
      }
      if (_stopsAdded) return;
    }

    Future<void> layer(String what, Future<void> Function() add) async {
      try {
        await add();
      } catch (e) {
        debugPrint('pm: layer $what failed: $e');
        if (mounted) {
          ref.read(mapStatusProvider.notifier).state = 'Livello $what non disponibile';
        }
      }
    }

    _stopsAdded = true;
    await layer('fermate', () async {
      await controller.addSource(
        _stopsSource,
        GeojsonSourceProperties(
          data: data,
          cluster: true,
          clusterRadius: 60,
          clusterMaxZoom: poleMinZoom - 1,
        ),
      );
    });

    final modeColor = [
      'match',
      ['get', 'mode'],
      'metro',
      _hex(tokens.modes.metro),
      'tram',
      _hex(tokens.modes.tram),
      'funicular',
      _hex(tokens.modes.funicular),
      _hex(tokens.modes.bus),
    ];

    await layer('gruppi', () async {
      await controller.addCircleLayer(
        _stopsSource,
        'pm-stop-clusters',
        CircleLayerProperties(
          circleColor: _hex(tokens.modes.bus),
          circleOpacity: 0.85,
          circleStrokeColor: _hex(surface),
          circleStrokeWidth: 2,
          circleRadius: [
            'interpolate',
            ['linear'],
            ['get', 'point_count'],
            2, 10.0,
            50, 18.0,
            300, 24.0,
          ],
        ),
        filter: ['has', 'point_count'],
      );
      await controller.addSymbolLayer(
        _stopsSource,
        'pm-stop-cluster-count',
        SymbolLayerProperties(
          textField: ['get', 'point_count_abbreviated'],
          textFont: const ['Noto Sans Regular'],
          textSize: 12,
          textColor: _hex(surface),
          textAllowOverlap: true,
          textIgnorePlacement: true,
        ),
        filter: ['has', 'point_count'],
        enableInteraction: false,
      );
    });

    await layer('pali', () async {
      // Invisible, larger circle first: a >= 44 px tap target (§14).
      await controller.addCircleLayer(
        _stopsSource,
        'pm-stop-touch',
        const CircleLayerProperties(circleRadius: 22.0, circleOpacity: 0.0),
        filter: ['!', ['has', 'point_count']],
        minzoom: poleMinZoom,
      );
      await controller.addCircleLayer(
        _stopsSource,
        'pm-stop-poles',
        CircleLayerProperties(
          circleColor: modeColor,
          circleRadius: [
            'interpolate',
            ['linear'],
            ['zoom'],
            15, 4.0,
            18, 7.0,
          ],
          circleStrokeColor: _hex(surface),
          circleStrokeWidth: 1.5,
        ),
        filter: ['!', ['has', 'point_count']],
        minzoom: poleMinZoom,
        enableInteraction: false,
      );
    });

    await layer('nomi fermata', () async {
      await controller.addSymbolLayer(
        _stopsSource,
        'pm-stop-labels',
        SymbolLayerProperties(
          textField: ['get', 'name'],
          textFont: const ['Noto Sans Regular'],
          textSize: 11,
          textOffset: [0, 1.1],
          textAnchor: 'top',
          textColor: _hex(onSurface),
          textHaloColor: _hex(surface),
          textHaloWidth: 1.4,
          // Constant opacity at every zoom: labels never fade (§10.1).
          textOpacity: 1.0,
          symbolSortKey: 0,
        ),
        filter: ['!', ['has', 'point_count']],
        minzoom: poleMinZoom,
        enableInteraction: false,
      );
    });
  }

  /// The search pin (§11.3): one circle annotation, cleared and redrawn.
  Future<void> _updatePin(Place? place) async {
    final controller = _controller;
    if (controller == null || !_styleReady) return;
    _pinned = place;
    final scheme = Theme.of(context).colorScheme;
    try {
      await controller.clearCircles();
      if (place == null) return;
      await controller.addCircle(
        CircleOptions(
          geometry: LatLng(place.lat, place.lon),
          circleRadius: 9,
          circleColor: _hex(scheme.primary),
          circleStrokeColor: _hex(scheme.surface),
          circleStrokeWidth: 3,
        ),
      );
    } catch (e) {
      debugPrint('pm: layer segnaposto failed: $e');
      if (mounted) {
        ref.read(mapStatusProvider.notifier).state =
            'Segnaposto non disponibile';
      }
    }
  }

  /// Rebuilds the vehicle layer. Adding it is isolated like every other layer:
  /// a failure shows a chip, the map and the stops stay up.
  Future<void> _updateVehicles(Iterable<RtVehicle> vehicles) async {
    final controller = _controller;
    if (controller == null || !_styleReady) return;
    final ix = ref.read(transitIndexProvider).valueOrNull;
    final data = vehicleFeatureCollection(ix, vehicles, _vehicleIds);
    // Read the theme before any await: the context may be gone afterwards.
    final tokens = Theme.of(context).brightness == Brightness.dark
        ? PmTokens.darkTokens
        : PmTokens.lightTokens;
    final surface = Theme.of(context).colorScheme.surface;

    if (_vehiclesAdded) {
      try {
        await controller.setGeoJsonSource(_vehiclesSource, data);
        return;
      } catch (_) {
        _vehiclesAdded = false;
      }
    }

    _vehiclesAdded = true;
    try {
      await addVehicleIcons(controller, tokens.modes);
      await controller.addSource(
        _vehiclesSource,
        GeojsonSourceProperties(data: data),
      );
      // White halo under the icon, then a >= 44 px invisible tap target.
      await controller.addCircleLayer(
        _vehiclesSource,
        'pm-vehicle-halos',
        CircleLayerProperties(
          circleColor: _hex(surface),
          circleOpacity: 0.9,
          circleRadius: [
            'interpolate',
            ['linear'],
            ['zoom'],
            11, 9.0,
            17, 17.0,
          ],
        ),
        minzoom: vehicleMinZoom,
        enableInteraction: false,
      );
      await controller.addSymbolLayer(
        _vehiclesSource,
        'pm-vehicle-icons',
        const SymbolLayerProperties(
          iconImage: ['concat', 'pm-veh-', ['get', 'mode']],
          iconSize: [
            'interpolate',
            ['linear'],
            ['zoom'],
            11, 0.8,
            17, 1.6,
          ],
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
        minzoom: vehicleMinZoom,
        enableInteraction: false,
      );
      await controller.addCircleLayer(
        _vehiclesSource,
        'pm-vehicle-touch',
        const CircleLayerProperties(circleRadius: 22.0, circleOpacity: 0.0),
        minzoom: vehicleMinZoom,
      );
    } catch (e) {
      debugPrint('pm: layer veicoli failed: $e');
      _vehiclesAdded = false;
      if (mounted) {
        ref.read(mapStatusProvider.notifier).state =
            'Livello veicoli non disponibile';
      }
    }
  }
}

String _hex(Color c) =>
    '#${((c.a * 255).round() << 24 | (c.r * 255).round() << 16 | (c.g * 255).round() << 8 | (c.b * 255).round()).toRadixString(16).padLeft(8, '0').substring(2)}';
