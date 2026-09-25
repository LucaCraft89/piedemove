import 'dart:typed_data';

import 'package:piedemove/data/transit_index.dart';

/// Builds a tiny index from a declarative spec, for unit tests.
///
///   stops:    (id, name, lat, lon)
///   patterns: (routeShortName, routeType, [stopIds], [[depSecondsPerStop]])
///
/// Each pattern is its own route; [regionalPatterns] marks some as coming from
/// the regional (scheduled-only) feed; [stopSequences] gives a pattern's GTFS
/// stop_sequence numbers when they are not 1, 2, 3...
TransitIndex syntheticIndex({
  required List<(String, String, double, double)> stops,
  required List<(String, int, List<String>, List<List<int>>)> patterns,
  int serviceStartDay = 20000,
  int serviceDayCount = 7,
  Set<int> regionalPatterns = const {},
  Map<int, List<int>> stopSequences = const {},
}) {
  final stopIds = [for (final s in stops) s.$1];
  final stopIndex = {for (var i = 0; i < stops.length; i++) stops[i].$1: i};

  final routeIds = <String>[];
  final routeShort = <String>[];
  final routeType = <int>[];
  final patternRoute = <int>[];
  final patternStopOffset = <int>[0];
  final patternStopFlat = <int>[];
  final patternTripOffset = <int>[0];
  final patternTripFlat = <int>[];
  final tripIds = <String>[];
  final tripPattern = <int>[];
  final tripTimeOffset = <int>[];
  final dep = <int>[];

  for (final (name, type, patternStops, trips) in patterns) {
    final p = patternRoute.length;
    routeIds.add('r$name$p');
    routeShort.add(name);
    routeType.add(type);
    patternRoute.add(p);
    patternStopFlat.addAll(patternStops.map((s) => stopIndex[s]!));
    patternStopOffset.add(patternStopFlat.length);
    for (final times in trips) {
      final t = tripIds.length;
      tripIds.add('t$p-$t');
      tripPattern.add(p);
      tripTimeOffset.add(dep.length);
      dep.addAll(times);
      patternTripFlat.add(t);
    }
    patternTripOffset.add(patternTripFlat.length);
  }

  final counts = Int32List(stops.length);
  for (var p = 0; p < patternRoute.length; p++) {
    for (var i = patternStopOffset[p]; i < patternStopOffset[p + 1]; i++) {
      counts[patternStopFlat[i]]++;
    }
  }
  final stopPatternOffset = Int32List(stops.length + 1);
  var acc = 0;
  for (var s = 0; s < stops.length; s++) {
    stopPatternOffset[s] = acc;
    acc += counts[s];
  }
  stopPatternOffset[stops.length] = acc;
  final cursor = Int32List.fromList(stopPatternOffset.sublist(0, stops.length));
  final stopPattern = Int32List(acc);
  final stopPatternPos = Int32List(acc);
  for (var p = 0; p < patternRoute.length; p++) {
    final base = patternStopOffset[p];
    for (var i = base; i < patternStopOffset[p + 1]; i++) {
      final at = cursor[patternStopFlat[i]]++;
      stopPattern[at] = p;
      stopPatternPos[at] = i - base;
    }
  }

  return TransitIndex(
    feedVersion: 'synthetic',
    serviceStartDay: serviceStartDay,
    serviceDayCount: serviceDayCount,
    stopIds: stopIds,
    stopCodes: stopIds,
    stopNames: [for (final s in stops) s.$2],
    stopLat: Float64List.fromList([for (final s in stops) s.$3]),
    stopLon: Float64List.fromList([for (final s in stops) s.$4]),
    routeIds: routeIds,
    routeShortNames: routeShort,
    routeLongNames: routeShort,
    routeTypes: Int8List.fromList(routeType),
    routeFeed: Int8List.fromList([
      for (var r = 0; r < routeIds.length; r++)
        regionalPatterns.contains(r) ? feedRegional : feedGtt,
    ]),
    patternRoute: Int32List.fromList(patternRoute),
    patternDir: Int8List(patternRoute.length),
    patternStopOffset: Int32List.fromList(patternStopOffset),
    patternStop: Int32List.fromList(patternStopFlat),
    // GTFS stop_sequence per position; patterns not listed count 1, 2, 3...
    patternSeq: stopSequences.isEmpty
        ? null
        : Int32List.fromList([
            for (var p = 0; p < patternRoute.length; p++)
              for (var i = 0;
                  i < patternStopOffset[p + 1] - patternStopOffset[p];
                  i++)
                stopSequences[p]?[i] ?? i + 1,
          ]),
    patternTripOffset: Int32List.fromList(patternTripOffset),
    patternTrip: Int32List.fromList(patternTripFlat),
    tripIds: tripIds,
    tripPattern: Int32List.fromList(tripPattern),
    tripService: Int32List(tripIds.length), // one service, index 0
    tripTimeOffset: Int32List.fromList(tripTimeOffset),
    tripDep: Int32List.fromList(dep),
    tripArr: Int32List.fromList(dep),
    // Single service, running every day of the window.
    serviceDays: Uint8List(serviceDayCount)..fillRange(0, serviceDayCount, 1),
    stopPatternOffset: stopPatternOffset,
    stopPattern: stopPattern,
    stopPatternPos: stopPatternPos,
  );
}

/// The date the synthetic calendar starts on.
DateTime syntheticDate({int serviceStartDay = 20000, int day = 1}) =>
    TransitIndex.dateOfEpochDay(serviceStartDay + day);
