/// The full-screen map and its stop layers.
///
/// Every layer is added in its own try/catch: a failed layer shows a status
/// chip, it never blanks the map (see CLAUDE.md, "Isolate failures").
library;

import 'dart:async' show Timer, unawaited;
import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/geo/line_providers.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/places/saved.dart';
import 'package:piedemove/ui/trip/trip_plan.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/location/device_location.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/sheets/line_picker.dart';
import 'package:piedemove/ui/theme/tokens.dart';

import 'package:piedemove/settings/settings.dart';
import 'basemap_style.dart';
import 'line_features.dart';
import 'me_layer.dart';
import 'map_style.dart';
import 'latest_runner.dart';
import 'map_focus.dart';
import 'stop_features.dart';
import 'vehicle_features.dart';

/// Turin, Porta Nuova.
const turin = LatLng(45.0625, 7.6785);
const _stopsSource = 'pm-stops';
const _linesSource = 'pm-lines';
const _connectorsSource = 'pm-connectors';
const _focusStopsSource = 'pm-focus-stops';
const _focusLinesSource = 'pm-focus-lines';

/// Ambient layers hidden while something is focused (never rebuilt or tiered).
const _ambientLayers = [
  'pm-line-casing',
  'pm-lines',
  'pm-lines-approx',
  'pm-line-picked',
  'pm-line-arrows',
  'pm-stop-connectors',
];
const _walkSource = 'pm-walk';
const _vehiclesSource = 'pm-vehicles';
const _entrancesSource = 'pm-entrances';

/// Vehicles appear from z12 (§10.1).
const vehicleMinZoom = 12.0;

/// Individual poles from z15; clusters below it.
const poleMinZoom = 15.0;

/// Non-null when a map layer failed to load; shown as a chip, never a blank map.
final mapStatusProvider = StateProvider<String?>((_) => null);

/// The "Veicoli" pill; off hides the layer without stopping the feed.
final vehiclesVisibleProvider = StateProvider<bool>((_) => true);

/// Routes a segment tap offered for picking; they draw thicker while the
/// picker is open (§9.8).
final linePickerProvider = StateProvider<List<int>>((_) => const []);

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

  late MapPalette _pal;
  String? _palName;
  String _styleJson = '';
  Timer? _styleTimer;
  bool get _mapDark => _pal.dark;
  Color get _haloColor => Color(int.parse('ff${_pal.halo.substring(1)}', radix: 16));
  Color get _textColor => Color(int.parse('ff${_pal.text.substring(1)}', radix: 16));

  /// A style that has not loaded after 10 s (tiles unreachable, no network)
  /// shows a chip; routing and the overlays keep working.
  void _watchStyle() {
    _styleJson = buildBasemapStyle(_pal);
    _styleTimer?.cancel();
    _styleTimer = Timer(const Duration(seconds: 10), () {
      if (!_styleReady && mounted) {
        ref.read(mapStatusProvider.notifier).state = 'Mappa di base non disponibile';
      }
    });
  }

  @override
  void dispose() {
    _styleTimer?.cancel();
    super.dispose();
  }

  /// A style reload drops every source, and `setGeoJsonSource` does not fail
  /// loudly on Android when the source is gone — so track it here.
  bool _stopsAdded = false;
  bool _stopsBusy = false;
  bool _vehiclesAdded = false;
  bool _vehiclesBusy = false;

  /// Feature id -> vehicle id, in the order the collection was built.
  final _vehicleIds = <String>[];

  bool _linesAdded = false;
  bool _linesBusy = false;
  bool _entrancesAdded = false;
  bool _meAdded = false;
  Position? _meDrawn;
  /// Dot operations run one at a time: add, move and raise must not interleave.
  Future<void> _meChain = Future.value();

  /// The place currently pinned by search, as last drawn.
  Place? _pinned;

  /// Focus last drawn, so a rebuild with the same focus costs nothing.
  MapFocus? _focus;
  bool _focusDrawn = false;
  List<int> _highlighted = const [];

  /// The focus the camera was last moved for: a redraw must not re-fit.
  MapFocus? _fitted;

  /// Live progress last drawn, packed as leg * 100000 + vertex; -1 = no trip.
  int _progress = -1;

  /// Walked geometry per leg index, once §9.10 has fetched it.

  @override
  Widget build(BuildContext context) {
    final kind = ref.watch(settingsProvider.select((s) => s.mapStyle));
    _pal = mapPalette(kind,
        appDark: Theme.of(context).brightness == Brightness.dark);
    if (_palName != _pal.name) {
      // New basemap: the plugin reloads the style; every layer is re-added
      // from onStyleLoadedCallback (the phase 4 pattern).
      if (_palName != null) _styleReady = false;
      _palName = _pal.name;
      _watchStyle();
    }
    // The index and the style race each other: whichever lands second runs
    // this. Watching, not listening — a value already there fires no event.
    if (ref.watch(transitIndexProvider).valueOrNull != null && !_stopsAdded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _addStops());
    }

    final vehicles = ref.watch(realtimeProvider.select((s) => s.vehicles));
    final showVehicles = ref.watch(vehiclesVisibleProvider);
    final focusNow = ref.watch(focusProvider);
    if (_styleReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ix = ref.read(transitIndexProvider).valueOrNull;
        _updateVehicles(showVehicles
            ? vehiclesForRoutes(
                ix, vehicles.values, ix == null ? null : focusRoutes(ix, focusNow))
            : const []);
      });
    }

    final ambient = ref.watch(ambientLinesProvider).valueOrNull;
    if (_styleReady && ambient != null && !_linesAdded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _addLines(ambient));
    }

    final entrances = ref.watch(metroEntrancesProvider).valueOrNull;
    if (_styleReady && entrances != null && !_entrancesAdded) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _addEntrances(entrances));
    }

    final focus = ref.watch(focusProvider);
    // Live progress redraws the same focus: the travelled split moved (§9.11).
    final progress = ref.watch(liveTripProvider
        .select((l) => l == null ? -1 : l.legIndex * 100000 + (l.along / 10).floor() + l.route.legs[l.legIndex].lat.length * 7));
    if (progress != _progress) {
      _progress = progress;
      _focusDrawn = false;
    }
    // The pattern geometry asset is only loaded once something is focused.
    final net = focus == null ? null : ref.watch(lineNetworkProvider).valueOrNull;
    if (_styleReady && _linesAdded && (focus != _focus || !_focusDrawn)) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _applyFocus(focus, net, ambient));
    }

    final picked = ref.watch(linePickerProvider);
    if (_styleReady && _linesAdded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _highlight(picked));
    }

    final me = ref.watch(myPositionProvider);
    if (_styleReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateMe(me));
    }

    final place = ref.watch(selectedPlaceProvider);
    if (_styleReady && !identical(place, _pinned)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updatePin(place));
    }

    return MapLibreMap(
      initialCameraPosition: const CameraPosition(target: turin, zoom: 13),
      styleString: _styleJson,
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
      onMapClick: (point, _) => _onMapClick(point),
      onStyleLoadedCallback: () {
        // A repeated callback for the same style would re-add every layer
        // ("already exists" -> a stuck status chip): once per style.
        if (_styleReady) return;
        _styleReady = true;
        _styleTimer?.cancel();
        if (ref.read(mapStatusProvider) == 'Mappa di base non disponibile') {
          ref.read(mapStatusProvider.notifier).state = null;
        }
        _stopsAdded = false;
        _stopsBusy = false;
        _vehiclesAdded = false;
        _vehiclesBusy = false;
        _linesAdded = false;
        _linesBusy = false;
        _entrancesAdded = false;
        _meAdded = false;
        _focusDrawn = false;
        _pinned = null;
        _addLines(ref.read(ambientLinesProvider).valueOrNull);
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


  /// Ambient network, connectors, focus stops and walking legs (§9.4-§9.10).
  /// Added below the stop layers, so a stop dot is never buried under a line.
  Future<void> _addLines(Map<String, dynamic>? ambient) async {
    final controller = _controller;
    if (controller == null || ambient == null || !_styleReady) return;
    // Read the theme before any await: the context may be gone afterwards.
    final tokens = _mapDark
        ? PmTokens.darkTokens
        : PmTokens.lightTokens;
    final surface = _haloColor;
    final onSurface = _textColor;
    final below = _stopsAdded ? 'pm-stop-clusters' : null;
    final empty = <String, dynamic>{'type': 'FeatureCollection', 'features': []};

    if (_linesBusy) return; // an add is in flight
    if (_linesAdded) {
      try {
        await controller.setGeoJsonSource(_linesSource, ambient);
        return;
      } catch (_) {
        _linesAdded = false;
      }
    }

    _linesAdded = true;
    _linesBusy = true;
    try {
      await controller.addSource(
        _linesSource,
        GeojsonSourceProperties(
          data: ambient,
          tolerance: lineSourceTolerance,
          buffer: lineSourceBuffer,
        ),
      );
      await controller.addLineLayer(
        _linesSource,
        'pm-line-casing',
        LineLayerProperties(
          lineColor: _hex(surface),
          lineWidth: ['+', ambientWidth, 2.0],
          lineOpacity: ['*', tierOpacity, 0.8],
          lineCap: 'round',
          lineJoin: 'round',
        ),
        belowLayerId: below,
        filter: notApproxFilter,
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _linesSource,
        'pm-lines',
        LineLayerProperties(
          lineColor: ambientColor(tokens.modes),
          // A journey's context line stays thin; everything else is ambient.
          lineWidth: ambientWidth,
          lineOpacity: tierOpacity,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        belowLayerId: below,
        filter: notApproxFilter,
        enableInteraction: false,
      );
      // Unsnapped hops: thin dotted, so a line never just stops (§9.3).
      await controller.addLineLayer(
        _linesSource,
        'pm-lines-approx',
        LineLayerProperties(
          lineColor: ambientColor(tokens.modes),
          lineWidth: approxLineWidth,
          lineOpacity: ['*', tierOpacity, approxLineOpacity],
          lineCap: 'round',
          lineJoin: 'round',
          lineDasharray: approxLineDash,
        ),
        belowLayerId: below,
        filter: isApproxFilter,
        enableInteraction: false,
      );
      // Picker candidates (§9.8): same source, thicker, filtered to the tap.
      await controller.addLineLayer(
        _linesSource,
        'pm-line-picked',
        LineLayerProperties(
          lineColor: ambientColor(tokens.modes),
          lineWidth: ['+', ambientWidth, 4.0],
          lineOpacity: 0.9,
          lineCap: 'round',
        ),
        belowLayerId: below,
        filter: ['in', r'$id', -1],
        enableInteraction: false,
      );
      // Arrows only where the segment is used in exactly one direction (§9.6).
      await controller.addSymbolLayer(
        _linesSource,
        'pm-line-arrows',
        SymbolLayerProperties(
          textField: '›',
          textFont: const ['Noto Sans Regular'],
          textSize: 16,
          textColor: _hex(onSurface),
          textHaloColor: _hex(surface),
          textHaloWidth: 1.0,
          textAllowOverlap: true,
          textIgnorePlacement: true,
          symbolPlacement: 'line',
          symbolSpacing: 90,
          textKeepUpright: false,
        ),
        belowLayerId: below,
        filter: ['==', ['get', 'arrow'], 1],
        minzoom: tier2MinZoom,
        enableInteraction: false,
      );
    } catch (e) {
      debugPrint('pm: layer linee failed: $e');
      _linesBusy = false;
      // Duplicate add across a style reload: the layers are there, carry on.
      if (!'$e'.contains('already exists')) {
        _linesAdded = false;
        if (mounted) {
          ref.read(mapStatusProvider.notifier).state = 'Linee non disponibili';
        }
        return;
      }
    }
    _linesBusy = false;

    // Focus lines: own source and layers, added once per style and only ever
    // updated by _applyFocus. Ambient tiering never applies to them.
    try {
      await controller.addSource(
        _focusLinesSource,
        GeojsonSourceProperties(
          data: empty,
          tolerance: lineSourceTolerance,
          buffer: lineSourceBuffer,
        ),
      );
      // Bottom to top: context casing+line, then ridden casing+line, so a
      // ridden stretch always sits above every context stretch (phase 3).
      for (final kind in const [kindContext, kindRidden]) {
        final ridden = kind == kindRidden;
        final filter = [
          'all',
          notApproxFilter,
          ['==', ['get', 'kind'], kind],
        ];
        await controller.addLineLayer(
          _focusLinesSource,
          'pm-focus-$kind-casing',
          LineLayerProperties(
            lineColor: _hex(surface),
            lineWidth: focusWidth(kind,
                extra: ridden ? riddenCasingExtra : contextCasingExtra),
            lineOpacity: 0.8,
            lineCap: 'round',
            lineJoin: 'round',
          ),
          belowLayerId: below,
          filter: filter,
          enableInteraction: false,
        );
        await controller.addLineLayer(
          _focusLinesSource,
          'pm-focus-$kind-lines',
          LineLayerProperties(
            lineColor: ambientColor(tokens.modes),
            lineWidth: focusWidth(kind),
            lineOpacity: [
              'case',
              ['==', ['get', 'travelled'], 1], travelledOpacity,
              1.0,
            ],
            lineCap: 'round',
            lineJoin: 'round',
          ),
          belowLayerId: below,
          filter: filter,
          enableInteraction: false,
        );
      }
      await controller.addLineLayer(
        _focusLinesSource,
        'pm-focus-approx',
        LineLayerProperties(
          lineColor: ambientColor(tokens.modes),
          lineWidth: approxLineWidth,
          lineOpacity: approxLineOpacity,
          lineCap: 'round',
          lineJoin: 'round',
          lineDasharray: approxLineDash,
        ),
        belowLayerId: below,
        filter: isApproxFilter,
        enableInteraction: false,
      );
      await controller.addSymbolLayer(
        _focusLinesSource,
        'pm-focus-arrows',
        SymbolLayerProperties(
          textField: '›',
          textFont: const ['Noto Sans Regular'],
          textSize: 16,
          textColor: _hex(onSurface),
          textHaloColor: _hex(surface),
          textHaloWidth: 1.0,
          textAllowOverlap: true,
          textIgnorePlacement: true,
          symbolPlacement: 'line',
          symbolSpacing: 90,
          textKeepUpright: false,
        ),
        belowLayerId: below,
        filter: ['==', ['get', 'arrow'], 1],
        enableInteraction: false,
      );
    } catch (e) {
      debugPrint('pm: layer linee selezionate failed: $e');
      if (mounted) {
        ref.read(mapStatusProvider.notifier).state =
            'Linea selezionata non disponibile';
      }
    }

    // Everything below is optional dressing: its own try/catch each.
    try {
      final connectors =
          await ref.read(stopConnectorsProvider.future) ?? empty;
      await controller.addSource(
        _connectorsSource,
        GeojsonSourceProperties(data: connectors),
      );
      await controller.addLineLayer(
        _connectorsSource,
        'pm-stop-connectors',
        LineLayerProperties(
          lineColor: _hex(onSurface),
          lineOpacity: 0.5,
          lineWidth: 1.2,
          lineDasharray: const [2.0, 2.0],
        ),
        belowLayerId: below,
        minzoom: poleMinZoom,
        enableInteraction: false,
      );
    } catch (e) {
      debugPrint('pm: layer raccordi failed: $e');
    }

    try {
      await controller.addSource(
        _walkSource,
        GeojsonSourceProperties(data: empty),
      );
      // White dotted casing under the dots, same absolute spacing.
      await controller.addLineLayer(
        _walkSource,
        'pm-walk-casing',
        LineLayerProperties(
          lineColor: '#FFFFFF',
          lineOpacity: 0.9,
          lineWidth: walkWidth + walkCasingExtra,
          lineCap: 'round',
          lineDasharray: walkDash(walkWidth + walkCasingExtra),
        ),
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _walkSource,
        'pm-walk-lines',
        LineLayerProperties(
          lineColor: walkColor(tokens.walk),
          lineOpacity: [
            'case',
            ['==', ['get', 'travelled'], 1], 0.4,
            1.0,
          ],
          lineWidth: walkWidth,
          lineCap: 'round',
          lineDasharray: walkDash(walkWidth),
        ),
        enableInteraction: false,
      );
    } catch (e) {
      debugPrint('pm: layer piedi failed: $e');
    }

    try {
      await controller.addSource(
        _focusStopsSource,
        GeojsonSourceProperties(data: empty),
      );
      // Mids first, ends in their own layer above: ends always win (phase 3).
      for (final end in const [false, true]) {
        await controller.addCircleLayer(
          _focusStopsSource,
          end ? 'pm-focus-stop-ends' : 'pm-focus-stop-dots',
          CircleLayerProperties(
            circleColor: [
              'match', ['get', 'mode'],
              'walk', _hex(onSurface),
              modeColor(tokens.modes),
            ],
            circleRadius: end
                ? endDot / 2
                : [
                    'interpolate', ['linear'], ['zoom'],
                    midDotMinZoom, midDot / 2 * midDotMinFactor,
                    midDotFullZoom, midDot / 2,
                  ],
            circleStrokeColor: _hex(surface),
            circleStrokeWidth: dotRingWidth,
          ),
          filter: ['==', ['get', 'big'], end ? 1 : 0],
        );
      }
      await controller.addSymbolLayer(
        _focusStopsSource,
        'pm-focus-stop-labels',
        SymbolLayerProperties(
          textField: ['get', 'name'],
          textFont: const ['Noto Sans Regular'],
          textSize: 11,
          textOffset: const [0, 1.2],
          textAnchor: 'top',
          textColor: _hex(onSurface),
          textHaloColor: _hex(surface),
          textHaloWidth: 1.6,
          textOpacity: 1,
          // Ends win collisions (sort key), so a dense route thins out
          // legibly at low zoom and shows every name once there is room.
          // ignore-placement must stay false: a layer that ignores placement
          // never enters the collision index, so its own labels pile up.
          textAllowOverlap: false,
          textIgnorePlacement: false,
          symbolSortKey: ['-', 0, ['get', 'big']],
        ),
        enableInteraction: false,
      );
    } catch (e) {
      debugPrint('pm: layer fermate percorso failed: $e');
    }
    // A style reload dropped the focus with the sources: draw it again.
    if (mounted && !_focusDrawn) setState(() {});
    unawaited(_raiseMe());
  }

  /// Metro entrances (§10.5): small dots with labels, metro colour, from z15.
  /// Its own try/catch like every other layer; failing costs the dots alone.
  Future<void> _addEntrances(Map<String, dynamic> entrances) async {
    final controller = _controller;
    if (controller == null || !_styleReady || _entrancesAdded) return;
    final tokens = _mapDark
        ? PmTokens.darkTokens
        : PmTokens.lightTokens;
    final surface = _haloColor;
    _entrancesAdded = true;
    try {
      await controller.addSource(
        _entrancesSource,
        GeojsonSourceProperties(data: entrances),
      );
      await controller.addCircleLayer(
        _entrancesSource,
        'pm-entrance-dots',
        CircleLayerProperties(
          circleColor: _hex(tokens.modes.metro),
          circleRadius: 3.5,
          circleStrokeColor: _hex(surface),
          circleStrokeWidth: 1.5,
        ),
        minzoom: poleMinZoom,
        enableInteraction: false,
      );
      await controller.addSymbolLayer(
        _entrancesSource,
        'pm-entrance-labels',
        SymbolLayerProperties(
          textField: ['get', 'name'],
          textFont: const ['Noto Sans Regular'],
          textSize: 10,
          textOffset: const [0, 1.0],
          textAnchor: 'top',
          textColor: _hex(tokens.modes.metro),
          textHaloColor: _hex(surface),
          textHaloWidth: 1.4,
        ),
        minzoom: poleMinZoom,
        enableInteraction: false,
      );
    } catch (e) {
      debugPrint('pm: layer ingressi metro failed: $e');
      _entrancesAdded = '$e'.contains('already exists');
    }
    unawaited(_raiseMe());
  }

  /// Focus rebuilds the sources so unrelated lines and stops are **absent**,
  /// never dimmed (§9.9). Clearing focus puts the ambient network back.
  final _focusRunner = LatestRunner();

  /// Queued and coalesced: overlapping draws (a tap during a fit animation or
  /// a style reload) used to interleave and leave stale data on the map.
  void _applyFocus(
    MapFocus? focus,
    LineNetwork? net,
    Map<String, dynamic>? ambient,
  ) {
    if (focus != null && net == null) return; // redraws when geometry lands
    _focus = focus;
    _focusDrawn = true;
    _focusRunner.request(() => _applyFocusNow(focus, net, ambient));
  }

  Future<void> _applyFocusNow(
    MapFocus? focus,
    LineNetwork? net,
    Map<String, dynamic>? ambient,
  ) async {
    final controller = _controller;
    final ix = ref.read(transitIndexProvider).valueOrNull;
    if (controller == null || !_styleReady || !_linesAdded || ix == null) return;
    // A focus whose geometry has not landed yet redraws when it does.
    if (focus != null && net == null) return;
    final wasFitted = _fitted;
    _fitted = focus;
    final empty = <String, dynamic>{'type': 'FeatureCollection', 'features': []};

    try {
      // Ambient layers are hidden, never re-sourced: their data and tiering
      // are untouched, so clearing the focus is a visibility flip.
      final focused = focus != null;
      for (final layer in _ambientLayers) {
        await controller.setLayerVisibility(layer, !focused);
      }
      switch (focus) {
        case null:
          await controller.setGeoJsonSource(_focusLinesSource, empty);
          await controller.setGeoJsonSource(_focusStopsSource, empty);
          await controller.setGeoJsonSource(_walkSource, empty);
          await _showAmbientStops(controller);
        case RouteFocus(:final route):
          final lines = routeFocusLines(ix, net!, route);
          // Fit first, then hand over the data: a source set while the camera
          // animates renders only some tiles on-device.
          if (focus != wasFitted) await _fitTo(controller, lines);
          await controller.setGeoJsonSource(_focusLinesSource, lines);
          await controller.setGeoJsonSource(
              _focusStopsSource, routeFocusStops(ix, route));
          await controller.setGeoJsonSource(_walkSource, empty);
          await _hideAmbientStops(controller);
        case JourneyFocus(:final journey):
          final live = ref.read(liveTripProvider);
          final lines = journeyFocusLines(ix, net!, journey, live: live);
          if (focus != wasFitted) {
            await _fitTo(controller, _journeyStops(ix, journey));
          }
          await controller.setGeoJsonSource(_focusLinesSource, lines);
          await controller.setGeoJsonSource(
              _focusStopsSource, _journeyStops(ix, journey));
          final (o, d) = _queryEnds();
          await controller.setGeoJsonSource(
            _walkSource,
            walkFeatures(
              ix,
              journey,
              path: (_) => null,
              originLat: o?.$1,
              originLon: o?.$2,
              destLat: d?.$1,
              destLon: d?.$2,
              live: live,
            ),
          );
          await _hideAmbientStops(controller);
          _noteApproximateWalks(journey);
      }
    } catch (e) {
      debugPrint('pm: focus failed: $e');
      _focusDrawn = false;
    }
  }

  /// Origin and destination of the planned trip (its own query, never the
  /// search pin: the pin is empty when the destination came from the planner).
  ((double, double)?, (double, double)?) _queryEnds() {
    final q = ref.read(tripPlanProvider).query;
    (double, double)? at(Place? p) => p == null ? null : (p.lat, p.lon);
    return (at(q.from), at(q.to));
  }

  Map<String, dynamic> _journeyStops(TransitIndex ix, Journey journey) {
    final (o, d) = _queryEnds();
    return journeyFocusStops(ix, journey, origin: o, destination: d);
  }

  /// Legs the walking graph did not cover stay straight dotted; say so once.
  void _noteApproximateWalks(Journey journey) {
    if (journey.walkApproximate) {
      ref.read(mapStatusProvider.notifier).state = 'Percorsi a piedi approssimati';
    }
  }

  /// Brings the focused route or journey into view; without it the map keeps
  /// whatever viewport it had and the selection is off screen.
  Future<void> _fitTo(
    MapLibreMapController controller,
    Map<String, dynamic> collection,
  ) async {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final f in collection['features'] as List) {
      final coords = f['geometry']['coordinates'] as List;
      // Point geometry is one pair; a LineString is a list of them.
      final pairs = coords.first is List ? coords.cast<List>() : [coords];
      for (final c in pairs) {
        final lon = (c[0] as num).toDouble(), lat = (c[1] as num).toDouble();
        if (lat < minLat) minLat = lat;
        if (lat > maxLat) maxLat = lat;
        if (lon < minLon) minLon = lon;
        if (lon > maxLon) maxLon = lon;
      }
    }
    if (minLat > maxLat || !mounted) return;
    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLon),
            northeast: LatLng(maxLat, maxLon),
          ),
          left: focusFitSide,
          right: focusFitSide,
          top: focusFitTop,
          // The sheet rests at peek.
          bottom: MediaQuery.of(context).size.height * sheetPeek +
              focusFitBottomExtra,
        ),
      );
    } catch (e) {
      debugPrint('pm: fit to focus failed: $e');
    }
  }

  static const _ambientStopLayers = [
    'pm-stop-poles',
    'pm-stop-labels',
    'pm-stop-clusters',
    'pm-stop-cluster-count',
  ];

  Future<void> _hideAmbientStops(MapLibreMapController controller) async {
    for (final layer in _ambientStopLayers) {
      await controller.setLayerVisibility(layer, false);
    }
  }

  Future<void> _showAmbientStops(MapLibreMapController controller) async {
    for (final layer in _ambientStopLayers) {
      await controller.setLayerVisibility(layer, true);
    }
  }

  /// Thickens the segments a picker is currently offering (§9.8).
  Future<void> _highlight(List<int> featureIds) async {
    final controller = _controller;
    if (controller == null || !_linesAdded) return;
    if (featureIds.join(',') == _highlighted.join(',')) return;
    _highlighted = featureIds;
    try {
      await controller.setFilter(
        'pm-line-picked',
        ['in', r'$id', ...featureIds.isEmpty ? [-1] : featureIds],
      );
    } catch (e) {
      debugPrint('pm: picker highlight failed: $e');
    }
  }

  /// A tap on the map away from a stop or vehicle: what line is under it?
  Future<void> _onMapClick(Point<double> point) async {
    final controller = _controller;
    final ix = ref.read(transitIndexProvider).valueOrNull;
    if (controller == null || ix == null || !_linesAdded) return;
    const pad = 22.0; // 44 px box (§9.8)
    List<dynamic> hits;
    try {
      hits = await controller.queryRenderedFeaturesInRect(
        Rect.fromLTRB(
            point.x - pad, point.y - pad, point.x + pad, point.y + pad),
        const ['pm-lines'],
        null,
      );
    } catch (e) {
      debugPrint('pm: query linee failed: $e');
      return;
    }

    final routes = <String, int>{}; // short name -> feature id
    final modes = <String, String?>{};
    for (final hit in hits) {
      final props = (hit as Map)['properties'] as Map?;
      final ids = (props?['routes'] as String?)?.split(',') ?? const [];
      // The platform hands the feature id back as a num on one side and a
      // String on the other; take either.
      final raw = hit['id'];
      final fid = raw is num ? raw.toInt() : int.tryParse('$raw');
      for (final r in ids) {
        if (r.isNotEmpty) {
          routes.putIfAbsent(r, () => fid ?? -1);
          modes.putIfAbsent(r, () => props?['mode'] as String?);
        }
      }
    }
    if (routes.isEmpty || !mounted) return;

    final picks = [
      for (final name in routes.keys)
        if (routeForTap(ix, name, modes[name]) != null)
          (name, routeForTap(ix, name, modes[name])!),
    ]..sort((a, b) => compareRouteNames(a.$1, b.$1));
    if (picks.isEmpty) return;
    if (picks.length == 1) {
      openEntity(context, ref, LineRef(picks.first.$2));
      return;
    }
    showLinePicker(
      context,
      ref,
      picks,
      featureIds: [for (final r in routes.values) if (r >= 0) r],
    );
  }

  Future<void> _addStops() async {
    final controller = _controller;
    final ix = ref.read(transitIndexProvider).valueOrNull;
    if (controller == null || ix == null || !_styleReady) return;

    final data = stopFeatureCollection(ix, ref.read(stopModesProvider));
    final tokens =
        _mapDark
            ? PmTokens.darkTokens
            : PmTokens.lightTokens;
    final onSurface = _textColor;
    final surface = _haloColor;

    if (_stopsBusy) return; // an add is in flight
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
        if (mounted && !'$e'.contains('already exists')) {
          ref.read(mapStatusProvider.notifier).state = 'Livello $what non disponibile';
        }
      }
    }

    _stopsAdded = true;
    _stopsBusy = true;
    await layer('fermate', () async {
      await controller.addSource(
        _stopsSource,
        GeojsonSourceProperties(
          data: data,
          cluster: true,
          clusterRadius: 60,
          clusterMaxZoom: poleMinZoom - 1,
          // Which modes ended up in this bubble: `max` over the per-stop flags.
          clusterProperties: {
            'b': ['max', ['get', 'b']],
            't': ['max', ['get', 't']],
            'm': ['max', ['get', 'm']],
            'f': ['max', ['get', 'f']],
          },
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

    // A bubble takes the most distinctive mode inside it: metro > funicular >
    // tram > bus, the same order as a mixed pole (`ModeColors.ofModes`).
    // ponytail: one colour, not a pie split — a split bubble needs a sprite per
    // combination, and maplibre-native would not show them.
    final clusterColor = [
      'case',
      ['==', ['get', 'm'], 1], _hex(tokens.modes.metro),
      ['==', ['get', 'f'], 1], _hex(tokens.modes.funicular),
      ['==', ['get', 't'], 1], _hex(tokens.modes.tram),
      _hex(tokens.modes.bus),
    ];

    await layer('gruppi', () async {
      await controller.addCircleLayer(
        _stopsSource,
        'pm-stop-clusters',
        CircleLayerProperties(
          circleColor: clusterColor,
          circleOpacity: 0.9,
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
    _stopsBusy = false;
    unawaited(_raiseMe());
  }

  /// The search pin (§11.3): one circle annotation, cleared and redrawn.
  /// Position dot: first call after a style load adds source + layers (top of
  /// the stack); later calls only move the data. Own try/catch, own chip.
  Future<void> _updateMe(Position? p) =>
      _meChain = _meChain.then((_) => _updateMeNow(p));

  Future<void> _updateMeNow(Position? p) async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    if (_meAdded && identical(p, _meDrawn)) return;
    _meDrawn = p;
    try {
      if (!_meAdded) {
        _meAdded = true;
        await addMeLayers(c, p);
      } else {
        await c.setGeoJsonSource(meSource, meFeatures(p));
      }
    } catch (e) {
      debugPrint('pm: position dot failed: $e');
      _meAdded = false;
      if (mounted) {
        ref.read(mapStatusProvider.notifier).state =
            'Posizione sulla mappa non disponibile';
      }
    }
  }

  /// Layers added after the dot would cover it: put it back on top.
  Future<void> _raiseMe() =>
      _meChain = _meChain.then((_) => _raiseMeNow());

  Future<void> _raiseMeNow() async {
    final c = _controller;
    if (c == null || !_meAdded) return;
    try {
      await raiseMeLayers(c);
    } catch (e) {
      debugPrint('pm: raise dot failed: $e');
      _meAdded = false; // next _updateMe re-adds it
    }
  }

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
    final tokens = _mapDark
        ? PmTokens.darkTokens
        : PmTokens.lightTokens;
    final surface = _haloColor;

    if (_vehiclesBusy) return; // an add is in flight; the next tick updates
    if (_vehiclesAdded) {
      try {
        await controller.setGeoJsonSource(_vehiclesSource, data);
        return;
      } catch (_) {
        _vehiclesAdded = false;
      }
    }

    _vehiclesAdded = true;
    _vehiclesBusy = true;
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
      // A duplicate add (two adds racing across a style reload) leaves the
      // layers in place: that is success, not a failure.
      final dup = '$e'.contains('already exists');
      _vehiclesAdded = dup;
      if (mounted && !dup) {
        ref.read(mapStatusProvider.notifier).state =
            'Livello veicoli non disponibile';
      }
    }
    _vehiclesBusy = false;
    unawaited(_raiseMe());
  }
}

String _hex(Color c) =>
    '#${((c.a * 255).round() << 24 | (c.r * 255).round() << 16 | (c.g * 255).round() << 8 | (c.b * 255).round()).toRadixString(16).padLeft(8, '0').substring(2)}';
