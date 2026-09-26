/// The basemap offline (rider request): an opt-in download of the vector
/// tiles over the area GTT serves, kept in MapLibre's offline database.
///
/// MapLibre downloads a region for a style **URL**; our style is built in
/// the app, so the region is OpenFreeMap's hosted positron style, which reads
/// the same `openmaptiles` source (`tiles.openfreemap.org/planet`) and Noto
/// Sans glyphs as ours. The offline database answers by resource URL, so
/// every one of our map styles draws from the downloaded tiles.
/// Fair use: vector tiles stop at z14 (the map overzooms past it), two
/// requests per host at a time, and only when the user asks.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';

const offlineStyleUrl = 'https://tiles.openfreemap.org/styles/positron';
const offlineMinZoom = 10;
const offlineMaxZoom = 14;

/// Above this many tiles the top zoom drops by one (and again): a region the
/// size of the whole GTT network at z14 would be hundreds of MB.
const offlineMaxTiles = 6000;

/// Vector tiles average well under this; the estimate errs large.
const offlineBytesPerTile = 30 * 1024;

const _regionName = 'piedemove-basemap';

typedef OfflineArea = ({double south, double west, double north, double east});

/// The area to keep: every stop of the GTT (live) network, padded ~1 km.
/// Regional scheduled-only stops would stretch it over all Piemonte.
OfflineArea? offlineArea(TransitIndex ix) {
  var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
  var any = false;
  for (var p = 0; p < ix.patternRoute.length; p++) {
    if (ix.isScheduledOnly(ix.patternRoute[p])) continue;
    for (var i = 0; i < ix.patternLength(p); i++) {
      final stop = ix.patternStopAt(p, i);
      final lat = ix.stopLat[stop], lon = ix.stopLon[stop];
      s = math.min(s, lat);
      n = math.max(n, lat);
      w = math.min(w, lon);
      e = math.max(e, lon);
      any = true;
    }
  }
  if (!any) return null;
  const pad = 0.01;
  return (south: s - pad, west: w - pad, north: n + pad, east: e + pad);
}

int _tileX(double lon, int z) => ((lon + 180) / 360 * (1 << z)).floor();
int _tileY(double lat, int z) {
  final r = lat * math.pi / 180;
  return ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) /
          2 *
          (1 << z))
      .floor();
}

/// Tiles covering [a] at zooms [minZ]..[maxZ].
int tileCount(OfflineArea a, int minZ, int maxZ) {
  var total = 0;
  for (var z = minZ; z <= maxZ; z++) {
    final x = (_tileX(a.east, z) - _tileX(a.west, z)).abs() + 1;
    final y = (_tileY(a.south, z) - _tileY(a.north, z)).abs() + 1;
    total += x * y;
  }
  return total;
}

/// The top zoom that keeps [a] within [offlineMaxTiles] (never below 12).
int offlineTopZoom(OfflineArea a) {
  var z = offlineMaxZoom;
  while (z > 12 && tileCount(a, offlineMinZoom, z) > offlineMaxTiles) {
    z--;
  }
  return z;
}

@immutable
class OfflineMapState {
  const OfflineMapState({
    this.region,
    this.progress,
    this.error,
    this.estimateBytes,
  });

  /// The downloaded (or downloading) region, when there is one.
  final OfflineRegion? region;

  /// 0..1 while downloading, else null.
  final double? progress;
  final String? error;
  final int? estimateBytes;

  bool get downloading => progress != null;
  bool get ready => region != null && progress == null && error == null;
}

class OfflineMapController extends StateNotifier<OfflineMapState> {
  OfflineMapController(this._ref) : super(const OfflineMapState()) {
    _refresh();
  }

  final Ref _ref;

  Future<void> _refresh() async {
    try {
      final regions = await getListOfRegions();
      final mine =
          regions.where((r) => r.metadata['name'] == _regionName).firstOrNull;
      if (mounted) state = OfflineMapState(region: mine, estimateBytes: _estimate());
    } catch (e) {
      debugPrint('pm: offline regions: $e');
      if (mounted) state = OfflineMapState(estimateBytes: _estimate());
    }
  }

  int? _estimate() {
    final ix = _ref.read(transitIndexProvider).valueOrNull;
    final area = ix == null ? null : offlineArea(ix);
    if (area == null) return null;
    return tileCount(area, offlineMinZoom, offlineTopZoom(area)) *
        offlineBytesPerTile;
  }

  Future<void> download() async {
    if (state.downloading) return;
    final ix = _ref.read(transitIndexProvider).valueOrNull;
    final area = ix == null ? null : offlineArea(ix);
    if (area == null) {
      state = const OfflineMapState(error: 'Orari non ancora pronti');
      return;
    }
    await remove(); // one region only: replace, never pile up
    state = OfflineMapState(progress: 0, estimateBytes: _estimate());
    try {
      final top = offlineTopZoom(area);
      await setOfflineTileCountLimit(tileCount(area, offlineMinZoom, top) + 500);
      await setOfflineMaxConcurrentRequests(maxRequestsPerHost: 2);
      final region = await downloadOfflineRegion(
        OfflineRegionDefinition(
          bounds: LatLngBounds(
            southwest: LatLng(area.south, area.west),
            northeast: LatLng(area.north, area.east),
          ),
          mapStyleUrl: offlineStyleUrl,
          minZoom: offlineMinZoom.toDouble(),
          maxZoom: top.toDouble(),
        ),
        metadata: {
          'name': _regionName,
          'at': DateTime.now().toIso8601String(),
          'zoom': top,
        },
        onEvent: (event) {
          if (!mounted) return;
          switch (event) {
            case InProgress(:final progress):
              state = OfflineMapState(
                  region: state.region,
                  progress: (progress / 100).clamp(0.0, 1.0),
                  estimateBytes: state.estimateBytes);
            case Success():
              state = OfflineMapState(
                  region: state.region, estimateBytes: state.estimateBytes);
            case Error(:final cause):
              state = OfflineMapState(
                  region: state.region,
                  error: cause.message ?? 'Download non riuscito',
                  estimateBytes: state.estimateBytes);
          }
        },
      );
      if (mounted) {
        state = OfflineMapState(
            region: region,
            progress: state.progress,
            error: state.error,
            estimateBytes: state.estimateBytes);
      }
    } catch (e) {
      debugPrint('pm: offline download: $e');
      if (mounted) {
        state = OfflineMapState(
            error: 'Download non riuscito', estimateBytes: _estimate());
      }
    }
  }

  Future<void> remove() async {
    try {
      for (final r in await getListOfRegions()) {
        if (r.metadata['name'] == _regionName) await deleteOfflineRegion(r.id);
      }
    } catch (e) {
      debugPrint('pm: offline delete: $e');
    }
    if (mounted) state = OfflineMapState(estimateBytes: _estimate());
  }
}

final offlineMapProvider =
    StateNotifierProvider<OfflineMapController, OfflineMapState>(
        OfflineMapController.new);
