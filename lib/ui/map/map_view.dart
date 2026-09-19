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
import 'package:piedemove/ui/theme/tokens.dart';

import 'stop_features.dart';

/// Turin, Porta Nuova.
const turin = LatLng(45.0625, 7.6785);
const _stopsSource = 'pm-stops';

/// Individual poles from z15; clusters below it.
const poleMinZoom = 15.0;

/// Non-null when a map layer failed to load; shown as a chip, never a blank map.
final mapStatusProvider = StateProvider<String?>((_) => null);

final mapControllerProvider = StateProvider<MapLibreMapController?>((_) => null);

typedef StopTap = void Function(int stopIndex);

class MapView extends ConsumerStatefulWidget {
  const MapView({super.key, this.onStopTap});

  final StopTap? onStopTap;

  @override
  ConsumerState<MapView> createState() => _MapViewState();
}

class _MapViewState extends ConsumerState<MapView> {
  MapLibreMapController? _controller;
  bool _styleReady = false;

  /// A style reload drops every source, and `setGeoJsonSource` does not fail
  /// loudly on Android when the source is gone — so track it here.
  bool _stopsAdded = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The index and the style race each other: whichever lands second runs
    // this. Watching, not listening — a value already there fires no event.
    if (ref.watch(transitIndexProvider).valueOrNull != null && !_stopsAdded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _addStops());
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
}

String _hex(Color c) =>
    '#${((c.a * 255).round() << 24 | (c.r * 255).round() << 16 | (c.g * 255).round() << 8 | (c.b * 255).round()).toRadixString(16).padLeft(8, '0').substring(2)}';
