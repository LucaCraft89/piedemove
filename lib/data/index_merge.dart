/// Phase 9: fold the Regione Piemonte bus feed into the GTT index.
///
/// The regional feed is scheduled only — no realtime, no shapes (183 MB of the
/// 216 MB, never read). Rules:
///
/// - a regional stop within [snapMetres] of a GTT stop **is** that GTT stop,
///   which is what creates the cross-feed transfers;
/// - a regional route whose stops are all covered adds nothing and is dropped;
/// - everything regional keeps `routeFeed == feedRegional`, so lines, vehicles
///   and live data skip it and the UI can label it "solo orario".
library;

import 'dart:typed_data';

import '../geo/distance.dart';
import 'transit_index.dart';

const _cellDegrees = 0.002; // ~220 m lat, ~157 m lon at 45°

int _cell(double lat, double lon) =>
    (lat / _cellDegrees).floor() * 1000000 + (lon / _cellDegrees).floor();

/// GTT stop covering [lat]/[lon] within [radius], or -1.
int _nearest(Map<int, List<int>> grid, TransitIndex ix, double lat, double lon,
    double radius) {
  var best = -1;
  var bestD = radius;
  final y = (lat / _cellDegrees).floor();
  final x = (lon / _cellDegrees).floor();
  for (var dy = -1; dy <= 1; dy++) {
    for (var dx = -1; dx <= 1; dx++) {
      for (final s in grid[(y + dy) * 1000000 + x + dx] ?? const <int>[]) {
        final d = haversineMetres(lat, lon, ix.stopLat[s], ix.stopLon[s]);
        if (d < bestD) {
          bestD = d;
          best = s;
        }
      }
    }
  }
  return best;
}

/// [gtt] plus whatever of [regional] is worth carrying. Neither input is
/// modified; ids coming from the regional feed are prefixed `R:`.
TransitIndex mergeRegional(TransitIndex gtt, TransitIndex regional,
    {double snapMetres = 150}) {
  final grid = <int, List<int>>{};
  for (var s = 0; s < gtt.stopCount; s++) {
    (grid[_cell(gtt.stopLat[s], gtt.stopLon[s])] ??= <int>[]).add(s);
  }

  // Covered regional stops become their GTT stop; the rest are new stops.
  final covered = Int32List(regional.stopCount)
    ..fillRange(0, regional.stopCount, -1);
  for (var s = 0; s < regional.stopCount; s++) {
    covered[s] = _nearest(
        grid, gtt, regional.stopLat[s], regional.stopLon[s], snapMetres);
  }

  // A route that never leaves GTT territory is already planned better by GTT.
  final keepRoute = List<bool>.filled(regional.routeCount, false);
  for (var p = 0; p < regional.patternCount; p++) {
    for (var i = 0; i < regional.patternLength(p); i++) {
      if (covered[regional.patternStopAt(p, i)] < 0) {
        keepRoute[regional.patternRoute[p]] = true;
        break;
      }
    }
  }

  // ---- stops ----------------------------------------------------------
  final stopIds = [...gtt.stopIds];
  final stopCodes = [...gtt.stopCodes];
  final stopNames = [...gtt.stopNames];
  final stopLat = [...gtt.stopLat];
  final stopLon = [...gtt.stopLon];
  final stopOf = Int32List(regional.stopCount)
    ..fillRange(0, regional.stopCount, -1);

  int mapStop(int s) {
    if (covered[s] >= 0) return covered[s];
    if (stopOf[s] >= 0) return stopOf[s];
    stopOf[s] = stopIds.length;
    stopIds.add('R:${regional.stopIds[s]}');
    stopCodes.add(regional.stopCodes[s]);
    stopNames.add(regional.stopNames[s]);
    stopLat.add(regional.stopLat[s]);
    stopLon.add(regional.stopLon[s]);
    return stopOf[s];
  }

  // ---- routes ---------------------------------------------------------
  final routeIds = [...gtt.routeIds];
  final routeShort = [...gtt.routeShortNames];
  final routeLong = [...gtt.routeLongNames];
  final routeTypes = [...gtt.routeTypes];
  final routeFeed = [...gtt.routeFeed];
  final routeOf = Int32List(regional.routeCount)
    ..fillRange(0, regional.routeCount, -1);
  for (var r = 0; r < regional.routeCount; r++) {
    if (!keepRoute[r]) continue;
    routeOf[r] = routeIds.length;
    routeIds.add('R:${regional.routeIds[r]}');
    routeShort.add(regional.routeShortNames[r]);
    routeLong.add(regional.routeLongNames[r]);
    routeTypes.add(regional.routeTypes[r]);
    routeFeed.add(feedRegional);
  }

  // ---- services: rebase both calendars onto one window ----------------
  final start = gtt.serviceStartDay < regional.serviceStartDay
      ? gtt.serviceStartDay
      : regional.serviceStartDay;
  final end = [
    gtt.serviceStartDay + gtt.serviceDayCount,
    regional.serviceStartDay + regional.serviceDayCount,
  ].reduce((a, b) => a > b ? a : b);
  final dayCount = end - start;
  final serviceCount = gtt.serviceCount + regional.serviceCount;
  final serviceDays = Uint8List(serviceCount * dayCount);
  void copyDays(TransitIndex ix, int base) {
    final shift = ix.serviceStartDay - start;
    for (var s = 0; s < ix.serviceCount; s++) {
      for (var d = 0; d < ix.serviceDayCount; d++) {
        serviceDays[(base + s) * dayCount + shift + d] =
            ix.serviceDays[s * ix.serviceDayCount + d];
      }
    }
  }

  copyDays(gtt, 0);
  copyDays(regional, gtt.serviceCount);

  // ---- patterns and trips ---------------------------------------------
  final patternRoute = [...gtt.patternRoute];
  final patternDir = [...gtt.patternDir];
  final patternStopOffset = [...gtt.patternStopOffset];
  final patternStop = [...gtt.patternStop];
  final patternSeq = [
    for (var p = 0; p < gtt.patternCount; p++)
      for (var i = 0; i < gtt.patternLength(p); i++) gtt.stopSequenceAt(p, i),
  ];
  final patternTripOffset = [...gtt.patternTripOffset];
  final patternTrip = [...gtt.patternTrip];
  final tripIds = [...gtt.tripIds];
  final tripPattern = [...gtt.tripPattern];
  final tripService = [...gtt.tripService];
  final tripTimeOffset = [...gtt.tripTimeOffset];
  final tripDep = [...gtt.tripDep];
  final tripArr = [...gtt.tripArr];

  for (var p = 0; p < regional.patternCount; p++) {
    final route = routeOf[regional.patternRoute[p]];
    if (route < 0) continue;
    patternRoute.add(route);
    patternDir.add(regional.patternDir[p]);
    final length = regional.patternLength(p);
    for (var i = 0; i < length; i++) {
      patternStop.add(mapStop(regional.patternStopAt(p, i)));
      patternSeq.add(regional.stopSequenceAt(p, i));
    }
    patternStopOffset.add(patternStop.length);
    final newPattern = patternRoute.length - 1;
    for (var i = 0; i < regional.patternTripCount(p); i++) {
      final t = regional.patternTripAt(p, i);
      patternTrip.add(tripIds.length);
      tripIds.add('R:${regional.tripIds[t]}');
      tripPattern.add(newPattern);
      tripService.add(gtt.serviceCount + regional.tripService[t]);
      tripTimeOffset.add(tripDep.length);
      for (var pos = 0; pos < length; pos++) {
        tripDep.add(regional.depOf(t, pos));
        tripArr.add(regional.arrOf(t, pos));
      }
    }
    patternTripOffset.add(patternTrip.length);
  }

  // ---- CSR: stop -> patterns (rebuilt over the merged arrays) ---------
  final stopCount = stopIds.length;
  final counts = Int32List(stopCount);
  for (final s in patternStop) {
    counts[s]++;
  }
  final stopPatternOffset = Int32List(stopCount + 1);
  var acc = 0;
  for (var s = 0; s < stopCount; s++) {
    stopPatternOffset[s] = acc;
    acc += counts[s];
  }
  stopPatternOffset[stopCount] = acc;
  final cursor = Int32List.fromList(stopPatternOffset.sublist(0, stopCount));
  final stopPattern = Int32List(acc);
  final stopPatternPos = Int32List(acc);
  for (var p = 0; p < patternRoute.length; p++) {
    final base = patternStopOffset[p];
    for (var i = base; i < patternStopOffset[p + 1]; i++) {
      final at = cursor[patternStop[i]]++;
      stopPattern[at] = p;
      stopPatternPos[at] = i - base;
    }
  }

  return TransitIndex(
    feedVersion: gtt.feedVersion,
    serviceStartDay: start,
    serviceDayCount: dayCount,
    stopIds: stopIds,
    stopCodes: stopCodes,
    stopNames: stopNames,
    stopLat: Float64List.fromList(stopLat),
    stopLon: Float64List.fromList(stopLon),
    routeIds: routeIds,
    routeShortNames: routeShort,
    routeLongNames: routeLong,
    routeTypes: Int8List.fromList(routeTypes),
    routeFeed: Int8List.fromList(routeFeed),
    patternRoute: Int32List.fromList(patternRoute),
    patternDir: Int8List.fromList(patternDir),
    patternStopOffset: Int32List.fromList(patternStopOffset),
    patternStop: Int32List.fromList(patternStop),
    patternSeq: Int32List.fromList(patternSeq),
    patternTripOffset: Int32List.fromList(patternTripOffset),
    patternTrip: Int32List.fromList(patternTrip),
    tripIds: tripIds,
    tripPattern: Int32List.fromList(tripPattern),
    tripService: Int32List.fromList(tripService),
    tripTimeOffset: Int32List.fromList(tripTimeOffset),
    tripDep: Int32List.fromList(tripDep),
    tripArr: Int32List.fromList(tripArr),
    serviceDays: serviceDays,
    stopPatternOffset: stopPatternOffset,
    stopPattern: stopPattern,
    stopPatternPos: stopPatternPos,
  );
}
