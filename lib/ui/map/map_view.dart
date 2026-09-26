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
import 'package:piedemove/geo/distance.dart';
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
import 'cluster_pies.dart';
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

/// Map layer problems by layer key; the first is shown as a chip, never a
/// blank map. A layer clears its own entry when it recovers, and a tap on the
/// chip dismisses them all.
class MapStatus extends StateNotifier<Map<String, String>> {
  MapStatus() : super(const {});

  void set(String key, String message) {
    if (state[key] != message) state = {...state, key: message};
  }

  void clear(String key) {
    if (state.containsKey(key)) state = {...state}..remove(key);
  }

  void dismissAll() => state = const {};
}

final mapStatusProvider =
    StateNotifierProvider<MapStatus, Map<String, String>>((_) => MapStatus());

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
        ref
            .read(mapStatusProvider.notifier)
            .set('basemap', 'Mappa di base non disponibile');
      }
    });
  }

  @override
  void dispose() {
    _styleTimer?.cancel();
    _controller?.onFeatureTapped.remove(_onFeatureTapped);
    super.dispose();
  }

  /// Bumped per style load. An add still awaiting from the previous style
  /// checks it and leaves the new style's flags alone.
  int _styleGen = 0;

  /// True once `pm-stop-clusters` exists on this style: line layers go below
  /// it, and fall back to the top of the stack when it is missing.
  bool _stopAnchor = false;

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

  /// The ambient network the lines source holds (identity), so a newer one
  /// from a lines update is swapped in without a style reload.
  Map<String, dynamic>? _ambientDrawn;

  /// Same for the connectors source and the focus geometry's network.
  Map<String, dynamic>? _connectorsDrawn;
  LineNetwork? _netDrawn;

  Future<void> _updateConnectors(Map<String, dynamic> connectors) async {
    final controller = _controller;
    if (controller == null || identical(connectors, _connectorsDrawn)) return;
    try {
      await controller.setGeoJsonSource(_connectorsSource, connectors);
      _connectorsDrawn = connectors;
    } catch (e) {
      debugPrint('pm: connectors update failed: $e');
    }
  }
  bool _entrancesAdded = false;
  bool _meAdded = false;
  Position? _meDrawn;
  /// Dot operations run one at a time: add, move and raise must not interleave.
  Future<void> _meChain = Future.value();

  /// Where the dot is drawn right now (a glide step, or the fix itself).
  (double, double)? _meAt;

  /// The last fix handed to the chain (drawn or about to be).
  Position? _meQueued;

  /// Bumped per fix: a glide still running for an older fix stops.
  int _meGlideGen = 0;

  /// The place currently pinned by search, as last drawn.
  (Place?, Place?, Place?)? _pins;

  /// The (from, to, list shown) the camera last framed.
  Object? _framed;

  /// Focus last drawn, so a rebuild with the same focus costs nothing.
  MapFocus? _focus;
  bool _focusDrawn = false;
  List<int> _highlighted = const [];

  /// The focus the camera was last moved for: a redraw must not re-fit.
  MapFocus? _fitted;

  /// Vehicles, visibility and focus last sent to the vehicle layer.
  Object? _vehiclesFor;

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
    // Only when something the layer shows changed: this build also runs for
    // every sheet opened or closed over the map, and re-sending every vehicle
    // across the platform channel each time made those transitions stutter.
    final vehiclesFor = (vehicles, showVehicles, focusNow);
    if (_styleReady && (!_vehiclesAdded || vehiclesFor != _vehiclesFor)) {
      _vehiclesFor = vehiclesFor;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ix = ref.read(transitIndexProvider).valueOrNull;
        _updateVehicles(!showVehicles
            ? const []
            // A trip shows only vehicles heading its way: both directions
            // of a line made "where is my bus" unreadable (rider report).
            : ix != null && focusNow is JourneyFocus
                ? vehiclesForJourney(ix, ref.read(lineNetworkProvider).valueOrNull,
                    vehicles.values, focusNow.journey)
                : vehiclesForRoutes(ix, vehicles.values,
                    ix == null ? null : focusRoutes(ix, focusNow)));
      });
    }

    final ambient = ref.watch(ambientLinesProvider).valueOrNull;
    // First add, or a newer network (a lines update landed): _addLines swaps
    // the data in place once the layers exist.
    if (_styleReady &&
        ambient != null &&
        (!_linesAdded || !identical(ambient, _ambientDrawn))) {
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
    // A lines update replaces the network: the focus drawn from the old one
    // is redrawn from the new one.
    if (net != null && !identical(net, _netDrawn)) {
      _netDrawn = net;
      _focusDrawn = false;
    }
    if (_styleReady && _linesAdded && (focus != _focus || !_focusDrawn)) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _applyFocus(focus, net, ambient));
    }

    // Connectors likewise: a new set swaps them in place.
    final connectors = ref.watch(stopConnectorsProvider).valueOrNull;
    if (_styleReady &&
        _connectorsDrawn != null &&
        connectors != null &&
        !identical(connectors, _connectorsDrawn)) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _updateConnectors(connectors));
    }

    final picked = ref.watch(linePickerProvider);
    if (_styleReady && _linesAdded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _highlight(picked));
    }

    final me = ref.watch(myPositionProvider);
    if (_styleReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateMe(me));
    }

    // Pins: the searched place, and the planned trip's start and end while
    // no journey is open (an open journey draws its own Partenza/Arrivo).
    final place = ref.watch(selectedPlaceProvider);
    final trip = ref.watch(tripPlanProvider);
    final openJourney = focus is JourneyFocus;
    final pins = (
      place,
      openJourney ? null : trip.query.from,
      openJourney ? null : trip.query.to,
    );
    if (_styleReady && pins != _pins) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updatePins(pins));
    }
    // A destination picked (or the results shown): frame start and end,
    // like a maps app, clear of the sheet that is up.
    final listUp =
        trip.result != null && !trip.sheetHidden && trip.selected == null;
    final frame = (trip.query.from, trip.query.to, listUp);
    if (_styleReady &&
        focus == null &&
        trip.query.to != null &&
        frame != _framed) {
      _framed = frame;
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _frameTrip(trip.query.from, trip.query.to!, listUp));
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
        _styleGen++;
        _styleTimer?.cancel();
        ref.read(mapStatusProvider.notifier).clear('basemap');
        _stopAnchor = false;
        _stopsAdded = false;
        _stopsBusy = false;
        _vehiclesAdded = false;
        _vehiclesBusy = false;
        _linesAdded = false;
        _ambientDrawn = null;
        _connectorsDrawn = null;
        _linesBusy = false;
        _entrancesAdded = false;
        _meAdded = false;
        _meAt = null;
        _focusDrawn = false;
        _pins = null;
        _pinsAdded = false;
        _framed = null;
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
    final travelled = _mapDark ? travelledColorDark : travelledColorLight;
    final below = _stopAnchor ? 'pm-stop-clusters' : null;
    final empty = <String, dynamic>{'type': 'FeatureCollection', 'features': []};
    final gen = _styleGen;
    final status = ref.read(mapStatusProvider.notifier);

    if (_linesBusy) return; // an add is in flight
    if (_linesAdded) {
      if (identical(ambient, _ambientDrawn)) return;
      try {
        await controller.setGeoJsonSource(_linesSource, ambient);
        _ambientDrawn = ambient;
        return;
      } catch (_) {
        _linesAdded = false;
      }
    }

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
          lineWidth: ambientWidth(extra: ambientCasingExtra),
          lineOpacity: tierOpacity(factor: ambientCasingOpacity),
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
          lineWidth: ambientWidth(),
          lineOpacity: tierOpacity(),
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
          lineOpacity: tierOpacity(factor: approxLineOpacity),
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
          lineWidth: ambientWidth(extra: pickedExtra),
          lineOpacity: pickedOpacity,
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
          textField: arrowGlyph,
          textFont: const ['Noto Sans Regular'],
          textSize: arrowTextSize,
          textColor: _hex(onSurface),
          textHaloColor: _hex(surface),
          textHaloWidth: arrowHaloWidth,
          textAllowOverlap: true,
          textIgnorePlacement: true,
          symbolPlacement: 'line',
          symbolSpacing: arrowSpacing,
          textKeepUpright: false,
        ),
        belowLayerId: below,
        filter: ['==', ['get', 'arrow'], 1],
        minzoom: tier2MinZoom,
        enableInteraction: false,
      );
    } catch (e) {
      debugPrint('pm: layer linee failed: $e');
      if (gen != _styleGen) return; // the style changed under us
      _linesBusy = false;
      // Duplicate add across a style reload: the layers are there, carry on.
      if (!'$e'.contains('already exists')) {
        if (mounted) status.set('lines', 'Linee non disponibili');
        return;
      }
    }
    if (gen != _styleGen) return;
    _linesBusy = false;
    _linesAdded = true;
    _ambientDrawn = ambient;
    status.clear('lines');

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
            lineOpacity: focusCasingOpacity,
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
            lineColor: [
              'case',
              isTravelled, _hex(travelled),
              ambientColor(tokens.modes),
            ],
            lineWidth: focusWidth(kind),
            lineOpacity: ['case', isTravelled, travelledOpacity, 1.0],
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
          textField: arrowGlyph,
          textFont: const ['Noto Sans Regular'],
          textSize: arrowTextSize,
          textColor: _hex(onSurface),
          textHaloColor: _hex(surface),
          textHaloWidth: arrowHaloWidth,
          textAllowOverlap: true,
          textIgnorePlacement: true,
          symbolPlacement: 'line',
          symbolSpacing: arrowSpacing,
          textKeepUpright: false,
        ),
        belowLayerId: below,
        filter: ['==', ['get', 'arrow'], 1],
        enableInteraction: false,
      );
      status.clear('focus');
    } catch (e) {
      debugPrint('pm: layer linee selezionate failed: $e');
      // Already there from an overlapping add: the layers work.
      if (mounted && !'$e'.contains('already exists')) {
        status.set('focus', 'Linea selezionata non disponibile');
      }
    }

    if (gen != _styleGen) return; // a newer style owns the map now
    // Everything below is optional dressing: its own try/catch each.
    try {
      final connectors =
          await ref.read(stopConnectorsProvider.future) ?? empty;
      await controller.addSource(
        _connectorsSource,
        GeojsonSourceProperties(data: connectors),
      );
      _connectorsDrawn = connectors;
      await controller.addLineLayer(
        _connectorsSource,
        'pm-stop-connectors',
        LineLayerProperties(
          lineColor: _hex(onSurface),
          lineOpacity: connectorOpacity,
          lineWidth: connectorWidth,
          lineDasharray: connectorDash,
        ),
        belowLayerId: below,
        minzoom: poleMinZoom,
        enableInteraction: false,
      );
    } catch (e) {
      debugPrint('pm: layer raccordi failed: $e');
    }

    if (gen != _styleGen) return; // a newer style owns the map now
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
          lineColor: walkCasingColor,
          lineOpacity: walkCasingOpacity,
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
          lineColor: ['case', isTravelled, _hex(travelled), walkColor(tokens.walk)],
          lineOpacity: ['case', isTravelled, travelledOpacity, 1.0],
          lineWidth: walkWidth,
          lineCap: 'round',
          lineDasharray: walkDash(walkWidth),
        ),
        enableInteraction: false,
      );
    } catch (e) {
      debugPrint('pm: layer piedi failed: $e');
    }

    if (gen != _styleGen) return; // a newer style owns the map now
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
    // A style reload mid-draw re-applies the focus on the new style itself
    // (_focusDrawn is reset there); this run must stop writing.
    final gen = _styleGen;

    try {
      // Ambient layers are hidden, never re-sourced: their data and tiering
      // are untouched, so clearing the focus is a visibility flip.
      final focused = focus != null;
      for (final layer in _ambientLayers) {
        await controller.setLayerVisibility(layer, !focused);
      }
      if (gen != _styleGen) return;
      if (focus is! JourneyFocus) _noteApproximateWalks(null);
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
            await _fitTo(controller, _journeyStops(ix, journey),
                bottomFraction: ref.read(liveTripProvider) != null
                    ? liveStripFraction
                    : sheetHalf);
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
  void _noteApproximateWalks(Journey? journey) {
    final status = ref.read(mapStatusProvider.notifier);
    if (journey != null && journey.walkApproximate) {
      status.set('walk', 'Percorsi a piedi approssimati');
    } else {
      status.clear('walk');
    }
  }

  /// Brings the focused route or journey into view; without it the map keeps
  /// whatever viewport it had and the selection is off screen.
  Future<void> _fitTo(
    MapLibreMapController controller,
    Map<String, dynamic> collection, {
    double bottomFraction = sheetPeek,
  }) async {
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
          // Clear of whatever sheet covers the bottom now (rider report:
          // the half-open trip sheet hid half the journey).
          bottom: MediaQuery.of(context).size.height * bottomFraction +
              focusFitBottomExtra,
        ),
      );
    } catch (e) {
      debugPrint('pm: fit to focus failed: $e');
    }
  }

  /// Start (or the rider, or nothing) and destination in view.
  Future<void> _frameTrip(Place? from, Place to, bool listUp) async {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final me = ref.read(myPositionProvider);
    final start = from != null
        ? (from.lat, from.lon)
        : (me == null ? null : (me.latitude, me.longitude));
    Map<String, dynamic> point(double lat, double lon) => {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [lon, lat],
          },
        };
    await _fitTo(
      controller,
      {
        'type': 'FeatureCollection',
        'features': [
          point(to.lat, to.lon),
          if (start != null) point(start.$1, start.$2),
        ],
      },
      bottomFraction: listUp ? sheetHalf : sheetPeek,
    );
  }

  static const _ambientStopLayers = [
    'pm-stop-poles',
    'pm-stop-labels',
    'pm-stop-clusters',
    'pm-stop-cluster-pies',
    'pm-stop-cluster-count',
  ];

  Future<void> _hideAmbientStops(MapLibreMapController controller) =>
      _setAmbientStops(controller, false);

  Future<void> _showAmbientStops(MapLibreMapController controller) =>
      _setAmbientStops(controller, true);

  /// Per layer: an optional one that failed to add (the pies) must not keep
  /// the others from hiding.
  Future<void> _setAmbientStops(
      MapLibreMapController controller, bool visible) async {
    for (final layer in _ambientStopLayers) {
      try {
        await controller.setLayerVisibility(layer, visible);
      } catch (e) {
        debugPrint('pm: $layer visibility failed: $e');
      }
    }
  }

  /// Thickens the segments a picker is currently offering (§9.8).
  Future<void> _highlight(List<int> featureIds) async {
    final controller = _controller;
    if (controller == null || !_linesAdded) return;
    if (featureIds.join(',') == _highlighted.join(',')) return;
    try {
      await controller.setFilter(
        'pm-line-picked',
        ['in', r'$id', ...featureIds.isEmpty ? [-1] : featureIds],
      );
      // Recorded only once applied, so a failed filter is retried.
      _highlighted = featureIds;
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
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);

    if (_stopsBusy) return; // an add is in flight
    final gen = _styleGen;
    final status = ref.read(mapStatusProvider.notifier);
    // Already on this style: replacing the data is enough.
    if (_stopsAdded) {
      try {
        await controller.setGeoJsonSource(_stopsSource, data);
      } catch (_) {
        _stopsAdded = false;
      }
      if (_stopsAdded) return;
    }

    /// True when the layer is there (added now, or already present).
    Future<bool> layer(String what, Future<void> Function() add) async {
      try {
        await add();
      } catch (e) {
        debugPrint('pm: layer $what failed: $e');
        if (!'$e'.contains('already exists')) {
          if (mounted && gen == _styleGen) {
            status.set('stops-$what', 'Livello $what non disponibile');
          }
          return false;
        }
      }
      status.clear('stops-$what');
      return true;
    }

    _stopsAdded = true;
    _stopsBusy = true;
    // Pie images first, before the source they draw (see cluster_pies.dart).
    final piesOk = await layer('gruppi per modo', () async {
      await addClusterPies(controller, tokens.modes, surface, pixelRatio);
    });
    if (gen != _styleGen) return;
    final sourceOk = await layer('fermate', () async {
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
    if (gen != _styleGen) return;
    if (!sourceOk) {
      // No source, no stop layers: retried on the next index or style event.
      _stopsAdded = false;
      _stopsBusy = false;
      return;
    }

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

    // Fallback colour under the pie (cluster_pies.dart): the most distinctive
    // mode inside, metro > funicular > tram > bus, as for a mixed pole.
    final clusterColor = [
      'case',
      ['==', ['get', 'm'], 1], _hex(tokens.modes.metro),
      ['==', ['get', 'f'], 1], _hex(tokens.modes.funicular),
      ['==', ['get', 't'], 1], _hex(tokens.modes.tram),
      _hex(tokens.modes.bus),
    ];

    final anchored = await layer('gruppi', () async {
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
    if (gen == _styleGen) _stopAnchor = anchored;

    // Equal slices, one per mode in the bubble, over the circle; a failure
    // leaves the one-colour circle.
    if (anchored && piesOk) {
      await layer('gruppi per modo', () async {
        await controller.addSymbolLayer(
          _stopsSource,
          'pm-stop-cluster-pies',
          SymbolLayerProperties(
            iconImage: clusterPieImage(),
            // Same size as the circle + stroke under it (radius 10..24 + 2).
            iconSize: [
              'interpolate',
              ['linear'],
              ['get', 'point_count'],
              2, 12.0 / clusterPieRadius,
              50, 20.0 / clusterPieRadius,
              300, 1.0,
            ],
            iconAllowOverlap: true,
            iconIgnorePlacement: true,
          ),
          filter: ['has', 'point_count'],
          belowLayerId: 'pm-stop-cluster-count',
          enableInteraction: false,
        );
      });
    }

    final poles = await layer('pali', () async {
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

    final names = await layer('nomi fermata', () async {
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
    if (gen == _styleGen) {
      // A group that failed is retried on a later build: the source and the
      // groups already there answer "already exists", which counts as done.
      _stopsAdded = anchored && poles && names;
      _stopsBusy = false;
    }
    unawaited(_raiseMe());
  }

  /// The search pin (§11.3): one circle annotation, cleared and redrawn.
  /// Position dot: first call after a style load adds source + layers (top of
  /// the stack); later calls only move the data. Own try/catch, own chip.
  Future<void> _updateMe(Position? p) {
    // Every map rebuild calls this; only a new fix may stop a glide, and it
    // must do so now, not when its turn in the chain comes.
    if (_meAdded && identical(p, _meQueued)) return _meChain;
    _meQueued = p;
    final glide = ++_meGlideGen;
    return _meChain = _meChain.then((_) => _updateMeNow(p, glide));
  }

  Future<void> _updateMeNow(Position? p, int glide) async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    if (_meAdded && identical(p, _meDrawn)) return;
    // Where the dot is on screen (mid-glide, if one was cut short).
    final from = _meAt ??
        (_meDrawn == null ? null : (_meDrawn!.latitude, _meDrawn!.longitude));
    _meDrawn = p;
    try {
      if (!_meAdded) {
        _meAdded = true;
        await addMeLayers(c, p);
        _meAt = p == null ? null : (p.latitude, p.longitude);
      } else if (from != null &&
          p != null &&
          haversineMetres(from.$1, from.$2, p.latitude, p.longitude) <=
              meGlideMaxMetres) {
        // Glide there; a newer fix (or style) cancels the rest of the steps.
        final step = meGlide ~/ meGlideSteps;
        for (final at
            in meGlidePoints(from.$1, from.$2, p.latitude, p.longitude)) {
          if (glide != _meGlideGen || !_meAdded) return;
          await c.setGeoJsonSource(meSource, meFeatures(p, at: at));
          _meAt = at;
          await Future<void>.delayed(step);
        }
      } else {
        await c.setGeoJsonSource(meSource, meFeatures(p));
        _meAt = p == null ? null : (p.latitude, p.longitude);
      }
      if (mounted) ref.read(mapStatusProvider.notifier).clear('me');
    } catch (e) {
      debugPrint('pm: position dot failed: $e');
      _meAdded = false;
      if (mounted) {
        ref
            .read(mapStatusProvider.notifier)
            .set('me', 'Posizione sulla mappa non disponibile');
      }
    }
  }

  /// Layers added after the dot would cover it: put it back on top.
  Future<void> _raiseMe() =>
      _meChain = _meChain.then((_) => _raiseMeNow());

  Future<void> _raiseMeNow() async {
    final c = _controller;
    if (c == null) return;
    // Pins first, then the dot: both above every layer added since. The pins
    // rise even without a fix (no dot yet).
    final look = _pinsLook;
    if (_pinsAdded && look != null) {
      try {
        await c.removeLayer(_pinsLayer);
        await c.addCircleLayer(_pinsSource, _pinsLayer, look,
            enableInteraction: false);
      } catch (e) {
        debugPrint('pm: raise pins failed: $e');
      }
    }
    if (!_meAdded) return;
    try {
      await raiseMeLayers(c);
    } catch (e) {
      debugPrint('pm: raise dot failed: $e');
      _meAdded = false; // next _updateMe re-adds it
    }
  }

  static const _pinsSource = 'pm-pins', _pinsLayer = 'pm-pins';
  bool _pinsAdded = false;

  /// The pin layer's look, kept so a raise can re-add it identically.
  CircleLayerProperties? _pinsLook;

  /// The searched place, and the planned trip's start (hollow) and
  /// destination (filled, larger). Our own layer, not the plugin's circle
  /// annotations: those sit below every line layer, so a destination on a
  /// busy street vanished under the lines (rider report, beta 9). It is
  /// kept on top, just under the position dot ([_raiseMeNow]).
  Future<void> _updatePins((Place?, Place?, Place?) pins) async {
    final controller = _controller;
    if (controller == null || !_styleReady || !mounted) return;
    _pins = pins;
    final (place, from, to) = pins;
    final scheme = Theme.of(context).colorScheme;
    final status = ref.read(mapStatusProvider.notifier);
    Map<String, dynamic> pin(Place p, String kind) => {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [p.lon, p.lat],
          },
          'properties': {'kind': kind},
        };
    final data = {
      'type': 'FeatureCollection',
      'features': [
        if (from != null && from.name != 'La mia posizione') pin(from, 'from'),
        if (place != null && !identical(place, to)) pin(place, 'place'),
        if (to != null) pin(to, 'to'),
      ],
    };
    try {
      if (_pinsAdded) {
        await controller.setGeoJsonSource(_pinsSource, data);
      } else {
        _pinsLook = CircleLayerProperties(
          circleRadius: [
            'match', ['get', 'kind'], 'to', 11.0, 'from', 7.0, 9.0,
          ],
          circleColor: [
            'match', ['get', 'kind'],
            'from', _hex(scheme.surface),
            _hex(scheme.primary),
          ],
          circleStrokeColor: [
            'match', ['get', 'kind'],
            'from', _hex(scheme.primary),
            _hex(scheme.surface),
          ],
          circleStrokeWidth: 3.0,
        );
        await controller.addSource(
            _pinsSource, GeojsonSourceProperties(data: data));
        await controller.addCircleLayer(_pinsSource, _pinsLayer, _pinsLook!,
            enableInteraction: false);
        _pinsAdded = true;
        unawaited(_raiseMe()); // the dot stays above the pins
      }
      status.clear('pin');
    } catch (e) {
      debugPrint('pm: layer segnaposto failed: $e');
      if (!'$e'.contains('already exists')) _pinsAdded = false;
      if (mounted) status.set('pin', 'Segnaposto non disponibile');
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

    if (_vehiclesBusy) {
      _vehiclesFor = null; // an add is in flight; the next build updates
      return;
    }
    final gen = _styleGen;
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
      if (gen != _styleGen) return;
      _vehiclesAdded = dup;
      if (mounted && !dup) {
        ref
            .read(mapStatusProvider.notifier)
            .set('vehicles', 'Livello veicoli non disponibile');
      }
    }
    if (gen != _styleGen) return;
    if (_vehiclesAdded && mounted) {
      ref.read(mapStatusProvider.notifier).clear('vehicles');
    }
    _vehiclesBusy = false;
    unawaited(_raiseMe());
  }
}

String _hex(Color c) =>
    '#${((c.a * 255).round() << 24 | (c.r * 255).round() << 16 | (c.g * 255).round() << 8 | (c.b * 255).round()).toRadixString(16).padLeft(8, '0').substring(2)}';
